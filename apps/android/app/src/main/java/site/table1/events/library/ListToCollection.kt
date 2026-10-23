package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Adding a deck or cube to the collection (contract/list-to-collection-2026-10-22.md): each line goes in as the
   printing and finish the list names, either what the collection lacks or every copy. Cases in
   testdata/list-to-collection/cases.json, shared with iOS and the web (ListToCollectionTest). */
object ListToCollection {
    enum class Mode(val wire: String) { Missing("missing"), All("all") }

    data class Op(val cardId: String, val finish: String, val delta: Int)

    /** Main and Commander always count, a deck's sideboard unless `sideboard` is false, Considering never. `owned` is
     *  keyed "card_id|finish" over every condition and language; `only` limits it to some printings (card detail). */
    fun ops(entries: List<ListEntry>, kind: ListKind, owned: Map<String, Int>, mode: Mode, sideboard: Boolean = true, only: Set<String>? = null): List<Op> {
        val need = LinkedHashMap<String, Int>()
        for (e in entries) {
            if (!(e.board == "main" || e.board == "commander" || (e.board == "side" && kind == ListKind.Deck && sideboard))) continue
            if (only != null && e.cardId !in only) continue
            need.merge(ownKey(e.cardId, e.finish), e.qty, Int::plus)
        }
        return need.mapNotNull { (k, n) ->
            val delta = if (mode == Mode.All) n else n - (owned[k] ?: 0)
            if (delta <= 0) null else k.split("|", limit = 2).let { Op(it[0], it[1], delta) }
        }.sortedWith(compareBy({ it.cardId }, { it.finish }))
    }

    fun copies(ops: List<Op>) = ops.sumOf { it.delta }

    /** Collection ops in the picked condition; an English printing goes in as the picked language, any other in its own. */
    fun collectionOps(ops: List<Op>, printingLang: (String) -> String?, condition: String, lang: String): List<CollectionOp> =
        ops.map { CollectionOp(it.cardId, it.finish, condition, Languages.forNew(printingLang(it.cardId) ?: "en", lang), delta = it.delta) }
}

/** Add to collection from a deck or cube: what's missing or every card, sideboard or not, in one undoable batch. */
@Composable
fun ListToCollectionScreen(list: CardList, owned: Map<String, Int>, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val cat by CatalogStore.state.collectAsState()
    val prefs = remember { T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE) }
    var condition by remember { mutableStateOf(prefs.getString("addCondition", "NM") ?: "NM") }
    var lang by remember { mutableStateOf(Languages.addLang) }
    var mode by remember { mutableStateOf(ListToCollection.Mode.Missing) }
    var sideboard by remember { mutableStateOf(true) }
    var printings by remember { mutableStateOf<Map<String, CatalogPrinting>>(emptyMap()) }
    var names by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var done by remember { mutableStateOf<Pair<String, Int>?>(null) } // batch id, copies

    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    LaunchedEffect(cat.generation, list.id) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val ids = list.entries.map { it.cardId }.toSet()
        val (ps, ns) = withContext(Dispatchers.Default) {
            val ps = db.printings(ids)
            val os = db.oracles(ps.values.map { it.oracleIdx }.toSet())
            ps to ps.mapValues { (_, p) -> os[p.oracleIdx]?.name ?: "Unknown card" }
        }
        printings = ps
        names = ns
    }

    val missing = ListToCollection.ops(list.entries, list.kind, owned, ListToCollection.Mode.Missing, sideboard)
    val all = ListToCollection.ops(list.entries, list.kind, owned, ListToCollection.Mode.All, sideboard)
    val ops = if (mode == ListToCollection.Mode.Missing) missing else all
    val copies = ListToCollection.copies(ops)
    val side = list.count("side")
    fun plural(n: Int) = "$n ${if (n == 1) "card" else "cards"}"

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Add to collection", list.name, onBack = onClose)
                LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    error?.let { e -> item { Notice(e, error = true) } }
                    done?.let { (batch, n) ->
                        item { Notice("Added ${plural(n)} to your collection.") }
                        item {
                            ListRow(if (busy) "Undoing…" else "Undo", "Takes those copies out again", onClick = {
                                if (busy) return@ListRow
                                busy = true
                                scope.launch {
                                    runCatching { CollectionStore.undo(batch) }.onSuccess { done = null }.onFailure { error = it.message }
                                    busy = false
                                }
                            })
                        }
                    }
                    item {
                        T1Segmented(listOf("Missing ${ListToCollection.copies(missing)}", "Every card ${ListToCollection.copies(all)}"),
                            if (mode == ListToCollection.Mode.Missing) 0 else 1) { mode = if (it == 0) ListToCollection.Mode.Missing else ListToCollection.Mode.All }
                    }
                    if (list.kind == ListKind.Deck && side > 0) item { ListRow("Sideboard", plural(side)) { T1Switch(sideboard) { sideboard = it } } }
                    item {
                        T1Segmented(Conditions.all, Conditions.all.indexOf(condition).coerceAtLeast(0)) { i ->
                            condition = Conditions.all[i]
                            prefs.edit().putString("addCondition", condition).apply()
                        }
                    }
                    item { NewCopiesLanguageRow { lang = it } }
                    item { Notice("Each card goes in as the printing and finish this ${if (list.kind == ListKind.Deck) "deck" else "cube"} lists. Considering isn't added.") }
                    item { Section("To add · $copies") }
                    if (ops.isEmpty()) item {
                        ListRow(if (mode == ListToCollection.Mode.Missing) "You own every card here" else "No cards to add",
                            if (mode == ListToCollection.Mode.Missing) "Pick Every card to add another copy of each" else null)
                    }
                    items(ops, key = { "${it.cardId}|${it.finish}" }) { o ->
                        val p = printings[o.cardId]
                        CardRow(p, names[o.cardId] ?: "…", listOfNotNull(p?.setLabel, if (o.finish == "nonfoil") null else Finish.of(o.finish)?.label ?: o.finish)
                            .joinToString(" · "), finish = o.finish) {
                            Text("+${o.delta}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                        }
                    }
                }
                Row(Modifier.fillMaxWidth().padding(bottom = 1.dp)) {
                    if (done != null) {
                        Ghost("Done") { onClose() }
                    } else {
                        Ghost(if (busy) "Adding…" else if (copies == 0) "Nothing to add" else "Add ${plural(copies)}",
                            enabled = !busy && copies > 0 && printings.isNotEmpty(), accent = true) {
                            if (ops.size > 5000) { error = "That's more than 5,000 different printings at once. Add the deck in parts."; return@Ghost }
                            busy = true
                            error = null
                            val n = copies
                            val sent = ops
                            scope.launch {
                                runCatching {
                                    CollectionStore.apply(ListToCollection.collectionOps(sent, { printings[it]?.lang }, condition, lang), source = "import")
                                }.onSuccess {
                                    done = it.batchId to n
                                    Telemetry.capture("list_added_to_collection", mapOf("kind" to list.kind.wire, "mode" to mode.wire,
                                        "sideboard" to sideboard, "copies" to n, "lines" to sent.size, "from" to "list"))
                                }.onFailure { error = it.message }
                                busy = false
                            }
                        }
                    }
                }
            }
        }
    }
}
