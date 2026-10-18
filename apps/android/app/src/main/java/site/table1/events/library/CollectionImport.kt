package site.table1.events.library

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.Stat
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1TextAction
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.time.LocalDate
import java.util.UUID

/* Library → Import and export (contract/collection-import-2026-10-17.md). Pick another app's CSV export, see what
   matched, fix or skip what didn't, then add it to the collection (or replace the collection with it) as
   collection_apply batches of up to 5000 ops, each with its own idempotency key, with one Undo for the lot.
   Export writes the collection in Moxfield's or ManaBox's layout. Same screen as iOS CollectionImport.swift. */

/**
 * Scryfall's set names (mtg_sets, readable signed out), for files that name the set instead of its code.
 * Kept on the device so an import works offline once the list has been read.
 */
object SetNames {
    @Serializable
    private data class Row(val code: String, val name: String)

    private var rows: List<Row> = emptyList()
    private var fetched = false
    private val prefs get() = T1App.instance.getSharedPreferences("library", Context.MODE_PRIVATE)

    suspend fun load(): List<Pair<String, String>> {
        if (rows.isEmpty()) {
            prefs.getString("setNames", null)?.let { saved ->
                runCatching { T1App.json.decodeFromString(ListSerializer(Row.serializer()), saved) }.onSuccess { rows = it }
            }
        }
        if (!fetched) {
            runCatching {
                // PostgREST returns 1000 rows a call; mtg_sets has over 1000.
                val all = ArrayList<Row>()
                for (start in 0L until 10_000L step 1000L) {
                    val page = T1App.supabase.from("mtg_sets").select(Columns.list("code", "name")) {
                        order("code", Order.ASCENDING)
                        range(start, start + 999)
                    }.decodeList<Row>()
                    all += page
                    if (page.size < 1000) break
                }
                all
            }.onSuccess { all ->
                rows = all
                fetched = true
                prefs.edit().putString("setNames", T1App.json.encodeToString(ListSerializer(Row.serializer()), all)).apply()
            } // Offline: the saved list (or none: set codes and names of cards still match).
        }
        return rows.map { it.code to it.name }
    }
}

class CollectionImportModel : ViewModel() {
    enum class Phase { Start, Reading, Preview, Writing, Done }

    /** One collection_apply call; its key is kept until the import is done, so Try again resends the same batch. */
    private data class Part(val key: String, val ops: List<CollectionOp>, val batchId: String? = null)

    var phase by mutableStateOf(Phase.Start); private set
    var error by mutableStateOf<String?>(null)
    var fileName by mutableStateOf(""); private set
    var format by mutableStateOf(CSVFormat.Other); private set
    var lines by mutableIntStateOf(0); private set
    var matched by mutableStateOf<List<ResolvedLine>>(emptyList()); private set
    var unmatched by mutableStateOf<List<ImportRow>>(emptyList()); private set
    var items by mutableStateOf<List<ImportItem>>(emptyList()); private set
    var fixed by mutableIntStateOf(0); private set
    var skipped by mutableIntStateOf(0); private set
    var mode by mutableStateOf("add")
    /** USD over the priced items, and how many items have a price. */
    var value by mutableStateOf<Pair<Double, Int>?>(null); private set
    private var parts by mutableStateOf<List<Part>>(emptyList())
    var batchIds by mutableStateOf<List<String>>(emptyList()); private set
    var undone by mutableStateOf(false); private set
    var exportNote by mutableStateOf<String?>(null); private set
    private var resolver: ImportResolver? = null

    val copies get() = items.sumOf { it.qty }
    val partsDone get() = parts.count { it.batchId != null }
    val retrying get() = partsDone > 0 && partsDone < parts.size

    /** Copies held now that a replace would remove (items the file doesn't have). */
    fun removedByReplace(held: Map<String, CollectionItem>): Int {
        val keep = items.mapTo(HashSet()) { it.key }
        return held.values.filter { it.key !in keep }.sumOf { it.qty }
    }

    fun reset() {
        phase = Phase.Start
        error = null
        matched = emptyList()
        unmatched = emptyList()
        items = emptyList()
        fixed = 0
        skipped = 0
        value = null
        parts = emptyList()
        batchIds = emptyList()
        undone = false
        resolver = null
    }

    fun read(context: Context, uri: Uri) {
        viewModelScope.launch {
            val file = withContext(Dispatchers.IO) {
                runCatching {
                    val resolver = context.contentResolver
                    val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                        if (c.moveToFirst()) c.getString(0) else null
                    } ?: uri.lastPathSegment ?: "file.csv"
                    val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: throw java.io.IOException("No stream")
                    name to bytes
                }.getOrNull()
            }
            if (file == null) error = "That file couldn't be opened." else read(file.second, file.first)
        }
    }

    suspend fun read(bytes: ByteArray, name: String) {
        val db = CatalogStore.db ?: run { error = "Card data is still loading."; return }
        reset()
        phase = Phase.Reading
        fileName = name
        val sets = SetNames.load()
        try {
            val (parsed, result, resolver) = withContext(Dispatchers.Default) {
                val parsed = CollectionCSV.parse(decode(bytes))
                val resolver = ImportResolver(db, sets)
                Triple(parsed, resolver.resolve(parsed.rows), resolver)
            }
            format = parsed.format
            lines = parsed.rows.size
            matched = result.first
            unmatched = result.second
            this.resolver = resolver
            refresh()
            phase = Phase.Preview
            Telemetry.capture("collection_import_previewed", mapOf("format" to format.wire, "lines" to lines,
                "matched" to matched.size, "unmatched" to unmatched.size))
            priceItems()
        } catch (e: Exception) {
            phase = Phase.Start
            error = e.message ?: "That file couldn't be read."
        }
    }

    /** UTF-8 nearly always; Windows exports (Excel) can be Latin-1. */
    private fun decode(bytes: ByteArray): String = try {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
    } catch (e: CharacterCodingException) {
        String(bytes, Charset.forName("windows-1252"))
    }

    fun fix(row: ImportRow, oracleIdx: Int) {
        val line = resolver?.resolve(row, oracleIdx) ?: return
        unmatched = unmatched - row
        matched = matched + line
        fixed++
        refresh()
        viewModelScope.launch { priceItems() }
    }

    fun skip(row: ImportRow) {
        unmatched = unmatched - row
        skipped++
    }

    fun skipAll() {
        skipped += unmatched.size
        unmatched = emptyList()
    }

    private fun refresh() {
        items = ImportResolver.items(matched)
        parts = emptyList()
    }

    private suspend fun priceItems() {
        val shown = items
        PriceBook.load(shown.map { it.cardId })
        var usd = 0.0
        var priced = 0
        for (it in shown) PriceBook.usd(it.cardId, it.finish)?.let { p -> usd += p * it.qty; priced++ }
        value = usd to priced
    }

    /** Writes the import: every chunk that hasn't landed yet, in order. */
    fun write() {
        viewModelScope.launch {
            phase = Phase.Writing
            error = null
            if (parts.isEmpty()) {
                val ops = if (mode == "replace") {
                    CollectionStore.sync()
                    val keep = items.mapTo(HashSet()) { it.key }
                    items.map { CollectionOp(it.cardId, it.finish, it.condition, it.lang, qty = it.qty) } +
                        CollectionStore.state.value.items.values.filter { it.key !in keep }
                            .map { CollectionOp(it.cardId, it.finish, it.condition, it.lang, qty = 0) }
                } else {
                    items.map { CollectionOp(it.cardId, it.finish, it.condition, it.lang, delta = it.qty) }
                }
                parts = ops.chunked(5000).map { Part(UUID.randomUUID().toString(), it) }
            }
            for (i in parts.indices) {
                if (parts[i].batchId != null) continue
                try {
                    val res = CollectionStore.apply(parts[i].ops, source = "import", key = parts[i].key)
                    parts = parts.toMutableList().also { it[i] = it[i].copy(batchId = res.batchId) }
                } catch (e: Exception) {
                    phase = Phase.Preview
                    val done = partsDone
                    val why = e.message ?: "Couldn't import"
                    error = if (done > 0) "Imported $done of ${parts.size} parts, then: $why Try again to send the rest." else why
                    return@launch
                }
            }
            batchIds = parts.mapNotNull { it.batchId }
            Telemetry.capture("collection_imported", mapOf("format" to format.wire, "mode" to mode, "cards" to copies,
                "items" to items.size, "parts" to parts.size, "fixed" to fixed, "skipped" to skipped))
            phase = Phase.Done
        }
    }

    /** Undoes every batch of the import, newest first. */
    suspend fun undo() {
        error = null
        while (batchIds.isNotEmpty()) {
            try {
                CollectionStore.undo(batchIds.last())
                batchIds = batchIds.dropLast(1)
            } catch (e: Exception) {
                error = e.message ?: "Couldn't undo"
                return
            }
        }
        undone = true
    }

    /** The collection as a CSV file in the app's cache, or null without card data. */
    suspend fun export(context: Context, layout: CollectionCSV.Layout): File? {
        val db = CatalogStore.db ?: return null
        val held = CollectionStore.state.value.items.values.toList()
        val sets = SetNames.load().toMap()
        val (text, cards, left) = withContext(Dispatchers.Default) {
            val printings = db.printings(held.mapTo(HashSet()) { it.cardId })
            val oracles = db.oracles(printings.values.mapTo(HashSet()) { it.oracleIdx })
            val rows = ArrayList<CollectionCSV.ExportCard>()
            var left = 0
            for (it in held) {
                val p = printings[it.cardId]
                val o = p?.let { oracles[p.oracleIdx] }
                if (p == null || o == null) { left += it.qty; continue }
                rows.add(CollectionCSV.ExportCard(o.name, p.set, sets[p.set] ?: p.set.uppercase(), p.cn, p.rarity, p.cardId,
                    it.finish, it.condition, it.lang, it.qty))
            }
            Triple(CollectionCSV.export(rows, layout), rows.sumOf { it.qty }, left)
        }
        val file = File(context.cacheDir, "export/table1-collection-${layout.wire}-${LocalDate.now()}.csv")
        try {
            withContext(Dispatchers.IO) {
                file.parentFile?.mkdirs()
                file.writeText(text)
            }
        } catch (e: Exception) {
            error = e.message
            return null
        }
        exportNote = if (left > 0) "$left card${if (left == 1) "" else "s"} newer than the card data ${if (left == 1) "was" else "were"} left out." else null
        Telemetry.capture("collection_exported", mapOf("layout" to layout.wire, "cards" to cards))
        return file
    }
}

/** The system share sheet for one CSV file (Save to Drive or Files, email, Nearby Share …). */
private fun share(context: Context, file: File) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.avatars", file)
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/csv"
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(send, file.name))
}

@Composable
fun CollectionImportScreen(onBack: () -> Unit, onAllCards: () -> Unit) {
    val model: CollectionImportModel = viewModel()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val cat by CatalogStore.state.collectAsState()
    val col by CollectionStore.state.collectAsState()
    var confirmReplace by remember { mutableStateOf(false) }
    var exporting by remember { mutableStateOf<CollectionCSV.Layout?>(null) }
    var undoing by remember { mutableStateOf(false) }
    var fixing by remember { mutableStateOf<ImportRow?>(null) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let { model.read(context, it) } }
    LaunchedEffect(Unit) {
        CatalogStore.load(userInitiated = true)
        Telemetry.screen("collection_import")
    }

    fixing?.let { row ->
        ImportFixScreen(row, onBack = { fixing = null }) { o ->
            fixing = null
            model.fix(row, o.idx)
        }
        return
    }

    val subtitle = when (model.phase) {
        CollectionImportModel.Phase.Start -> col.summary?.let { "${count(it.totalQty)} cards in collection" }
        CollectionImportModel.Phase.Reading -> "Reading…"
        CollectionImportModel.Phase.Preview, CollectionImportModel.Phase.Writing -> model.format.label
        CollectionImportModel.Phase.Done -> if (model.undone) "Import undone" else "Imported"
    }
    val ready = cat.phase == "ready" && CatalogStore.db != null
    val copies = model.copies

    T1Screen {
        Bar("Import and export", subtitle = subtitle, onBack = onBack)
        CatalogStatus(cat)
        model.error?.let { Notice(it, error = true) }
        Hairlines(Modifier.weight(1f)) {
            when (model.phase) {
                CollectionImportModel.Phase.Start, CollectionImportModel.Phase.Reading -> {
                    item { Section("Import") }
                    item {
                        BigAction("Choose a file", enabled = ready, busy = model.phase == CollectionImportModel.Phase.Reading) {
                            pick.launch(arrayOf("text/*", "application/csv", "application/vnd.ms-excel"))
                        }
                    }
                    item {
                        Notice("Export the collection as CSV from ManaBox, Moxfield, Archidekt, Deckbox, Dragon Shield, TCGplayer or Delver Lens, then choose the file here. A card name and its set are enough; collector number, foil, condition and language are read when the file has them.")
                    }
                    item { Section("Export") }
                    items(CollectionCSV.Layout.entries) { layout ->
                        val enabled = exporting == null && ready && col.items.isNotEmpty()
                        ListRow("For ${layout.label}", if (exporting == layout) "Writing…" else "CSV in ${layout.label}'s layout",
                            onClick = if (!enabled) null else {
                                {
                                    exporting = layout
                                    scope.launch {
                                        model.export(context, layout)?.let { share(context, it) }
                                        exporting = null
                                    }
                                }
                            })
                    }
                    model.exportNote?.let { note -> item { Notice(note) } }
                }

                CollectionImportModel.Phase.Preview, CollectionImportModel.Phase.Writing -> {
                    val writing = model.phase == CollectionImportModel.Phase.Writing
                    item { ListRow(model.fileName, "${model.format.label} · ${count(model.lines)} lines") }
                    item {
                        Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp),
                            horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                            Stat("Matched", "${count(copies)} cards", accent = true)
                            Stat("Printings", count(model.items.size))
                            Stat("Value", model.value.let { v -> if (v == null) "…" else if (v.second == 0) "—" else money(v.first, "USD") }, end = true)
                        }
                    }
                    if (model.unmatched.isNotEmpty()) {
                        item {
                            Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                Label("Not matched · ${model.unmatched.size}", Modifier.weight(1f))
                                BarAction("Skip all") { model.skipAll() }
                            }
                        }
                        items(model.unmatched, key = { "u${it.line}" }) { r ->
                            UnmatchedRow(r, onFix = { fixing = r }, onSkip = { model.skip(r) })
                        }
                    }
                    item {
                        T1Segmented(listOf("Add to collection", "Replace collection"), if (model.mode == "replace") 1 else 0, enabled = !writing) {
                            model.mode = if (it == 1) "replace" else "add"
                        }
                    }
                    if (model.mode == "replace") {
                        item {
                            Notice("Your collection becomes exactly this file: ${count(model.removedByReplace(col.items))} cards that aren't in it are removed. Undo puts them back.")
                        }
                    }
                    if (model.unmatched.isNotEmpty()) item { Notice("Lines left unmatched aren't imported. Fix them or skip them first.") }
                    item {
                        val text = when {
                            model.retrying -> "Try again"
                            model.mode == "replace" -> "Replace with ${count(copies)} cards"
                            else -> "Import ${count(copies)} cards"
                        }
                        BigAction(text, enabled = model.unmatched.isEmpty() && (copies > 0 || model.mode == "replace"), busy = writing) {
                            if (model.mode == "replace" && !model.retrying) confirmReplace = true else model.write()
                        }
                    }
                    item { Section("Matched · ${count(model.matched.size)} lines") }
                    items(model.matched.take(80), key = { "m${it.row.line}" }) { l ->
                        CardRow(l.printing, l.row.name.ifEmpty { l.printing.setLabel }, detail(l)) {
                            Text("${l.row.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                        }
                    }
                    if (model.matched.size > 80) item { Notice("And ${count(model.matched.size - 80)} more lines.") }
                    item { ListRow("Choose another file", onClick = if (writing) null else model::reset) }
                }

                CollectionImportModel.Phase.Done -> {
                    item {
                        Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 14.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Column(Modifier.weight(1f)) {
                                Text(if (model.undone) "Import undone" else "${if (model.mode == "replace") "Replaced with" else "Imported"} ${count(copies)} cards",
                                    color = T1.text, fontFamily = T1.mono, fontSize = 14.sp)
                                Label("${count(model.items.size)} printings · ${model.format.label}")
                            }
                            if (!model.undone) {
                                BarAction(if (undoing) "Undoing…" else "Undo") {
                                    if (undoing) return@BarAction
                                    undoing = true
                                    scope.launch { model.undo(); undoing = false }
                                }
                            }
                        }
                    }
                    item { ListRow("All cards", col.summary?.let { "${count(it.totalQty)} cards in collection" }, onClick = onAllCards) }
                    item { ListRow("Import another file", onClick = model::reset) }
                }
            }
        }
    }

    if (confirmReplace) {
        T1AlertDialog(
            title = "Replace your collection?",
            onDismiss = { confirmReplace = false },
            body = {
                Text("Your collection becomes exactly this file. ${count(model.removedByReplace(col.items))} cards that aren't in it are removed. Undo puts them back.",
                    fontFamily = T1.mono, color = T1.muted, fontSize = 13.sp)
            },
            confirm = { T1TextAction("Replace", color = T1.danger) { confirmReplace = false; model.write() } },
            dismiss = { T1TextAction("Cancel") { confirmReplace = false } },
        )
    }
}

private fun detail(l: ResolvedLine) = listOfNotNull(l.printing.setLabel, if (l.finish == "nonfoil") null else Finish.of(l.finish)?.label,
    l.row.condition, if (l.row.lang == "en") null else l.row.lang.uppercase()).joinToString(" · ")

@Composable
private fun UnmatchedRow(r: ImportRow, onFix: () -> Unit, onSkip: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        Column(Modifier.weight(1f).padding(horizontal = 16.dp, vertical = 10.dp)) {
            Text(r.name.ifEmpty { "No name" }, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Label(listOfNotNull(r.problem, "Line ${r.line}", r.setLabel.ifEmpty { null }, "${r.qty} cop${if (r.qty == 1) "y" else "ies"}").joinToString(" · "))
        }
        RowButton("Fix", onFix)
        RowButton("Skip", onSkip)
    }
}

@Composable
private fun RowButton(text: String, onClick: () -> Unit) {
    Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable(onClick = onClick).padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center) { Label(text, color = T1.text) }
}

/** Fix one unmatched line: search the catalog with the line's name filled in, pick the card. */
@Composable
private fun ImportFixScreen(row: ImportRow, onBack: () -> Unit, onPick: (CatalogOracle) -> Unit) {
    var query by remember { mutableStateOf(row.name) }
    var hits by remember { mutableStateOf<List<CatalogOracle>>(emptyList()) }
    var covers by remember { mutableStateOf<Map<Int, CatalogPrinting>>(emptyMap()) }
    val focus = remember { FocusRequester() }
    BackHandler(onBack = onBack)
    LaunchedEffect(Unit) {
        Telemetry.screen("collection_import_fix")
        runCatching { focus.requestFocus() }
    }
    LaunchedEffect(query) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        delay(120) // let typing settle
        val q = query
        val found = withContext(Dispatchers.Default) {
            // A name with set or version noise ("Bolt (Borderless)") still finds the card by its first words.
            var h = db.search(q)
            if (h.isEmpty()) q.indexOfFirst { it == '(' || it == '[' }.takeIf { it > 0 }?.let { h = db.search(q.substring(0, it)) }
            h to db.covers(h.map { it.idx })
        }
        hits = found.first
        covers = found.second
    }
    T1Screen {
        Bar("Line ${row.line}", subtitle = listOf(row.name, row.setLabel).filter { it.isNotEmpty() }.joinToString(" · "), onBack = onBack)
        Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp).focusRequester(focus)) {
            T1TextField(query, { query = it }, label = "Card name")
        }
        Hairlines(Modifier.weight(1f)) {
            if (CardName.norm(query).length >= 2 && hits.isEmpty()) item { QuietRow("No card by that name") }
            items(hits, key = { it.idx }) { o ->
                CardRow(covers[o.idx], o.name, o.typeLine, onClick = { onPick(o) }) { Label("Pick", color = T1.text) }
            }
        }
    }
}
