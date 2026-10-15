package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.jan.supabase.functions.functions
import io.ktor.client.plugins.timeout
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1

// Import a deck or cube from a link (Cube Cobra, Archidekt, MTGGoldfish, ManaBox and other pages) or a pasted list
// (Moxfield, ManaBox, Arena, MTGO exports); contract/list-import-2026-10-15.md. Lines resolve to exact printings
// when the source names them, else to the card's original paper printing. Same flow as iOS and the web.

@Serializable
data class ImportedList(
    val kind: String? = null,
    val name: String? = null,
    val format: String? = null,
    @SerialName("source_url") val sourceUrl: String? = null,
    val entries: List<Line> = emptyList(),
    val error: String? = null,
) {
    @Serializable
    data class Line(
        val qty: Int, val board: String = "main", val name: String,
        val set: String? = null, val cn: String? = null,
        @SerialName("scryfall_id") val scryfallId: String? = null, val finish: String? = null,
    )
}

data class ResolvedImport(val entries: List<ListEntry>, val printings: Map<String, CatalogPrinting>, val names: Map<String, String>, val missing: List<String>)

/** Scryfall id, then set + collector number, then the name's original printing. Cubes fold side/commander into main. */
fun resolveImport(lines: List<ImportedList.Line>, kind: ListKind, db: CatalogDb): ResolvedImport {
    val byId = db.printings(lines.mapNotNull { it.scryfallId?.lowercase() })
    val bySet = db.printingsBySetCn(lines.mapNotNull { l -> l.set?.let { s -> l.cn?.let { s to it } } })
    val byName = db.printingsByName(lines.map { it.name })
    val entries = LinkedHashMap<String, ListEntry>()
    val printings = HashMap<String, CatalogPrinting>()
    val names = HashMap<String, String>()
    val missing = sortedSetOf<String>()
    for (l in lines) {
        val p = l.scryfallId?.let { byId[it.lowercase()] } ?: l.set?.let { s -> l.cn?.let { bySet["$s|$it"] } } ?: byName[l.name]
        if (p == null) { missing += l.name; continue }
        val finish = l.finish?.takeIf { f -> p.finishList.any { it.wire == f } } ?: "nonfoil"
        var board = l.board.takeIf { it in listOf("main", "side", "maybe", "commander") } ?: "main"
        if (kind == ListKind.Cube && (board == "side" || board == "commander")) board = "main"
        printings[p.cardId] = p
        names[p.cardId] = l.name
        val k = "$board|${p.cardId}|$finish"
        entries[k] = entries[k]?.let { it.copy(qty = minOf(999, it.qty + l.qty)) } ?: ListEntry(p.cardId, board, l.qty, finish)
    }
    return ResolvedImport(entries.values.toList(), printings, names, missing.toList())
}

private suspend fun readImport(link: String, text: String): ImportedList = try {
    val response = T1App.supabase.functions.invoke("list-import") {
        contentType(ContentType.Application.Json)
        setBody(buildJsonObject { if (link.isNotBlank()) put("url", link.trim()) else put("text", text) }.toString())
        timeout { requestTimeoutMillis = 90_000 }
    }
    T1App.json.decodeFromString<ImportedList>(response.bodyAsText())
} catch (e: Exception) {
    // A refusal (Moxfield, a private list) carries the server's own message.
    val msg = e.message?.let { m -> Regex("\"error\"\\s*:\\s*\"([^\"]+)\"").find(m)?.groupValues?.get(1) }
    ImportedList(error = msg ?: "That list couldn't be read.")
}

private val IMPORT_DECK_FORMATS = listOf("modern", "pioneer", "standard", "legacy", "vintage", "pauper", "commander", "canlander", "other")
private val IMPORT_CUBE_FORMATS = listOf("vintage", "legacy", "pauper", "peasant", "other")

@Composable
fun ListImportScreen(kind: ListKind, onBack: () -> Unit, onCreated: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var link by remember { mutableStateOf("") }
    var text by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var result by remember { mutableStateOf<ImportedList?>(null) }
    var resolved by remember { mutableStateOf<ResolvedImport?>(null) }
    var name by remember { mutableStateOf("") }
    val formats = if (kind == ListKind.Deck) IMPORT_DECK_FORMATS else IMPORT_CUBE_FORMATS
    var format by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }

    fun read() {
        busy = true; error = null
        scope.launch {
            val r = readImport(link, text)
            val db = CatalogStore.db
            when {
                r.error != null -> error = r.error
                r.entries.isEmpty() -> error = "No cards in that list."
                db == null -> error = "Card data is still loading. Try again in a moment."
                else -> {
                    resolved = withContext(Dispatchers.Default) { resolveImport(r.entries, kind, db) }
                    name = (r.name ?: "").take(60)
                    formats.indexOf(r.format).takeIf { it >= 0 }?.let { format = it }
                    result = r
                }
            }
            busy = false
        }
    }
    fun create() {
        val res = resolved ?: return
        busy = true
        val host = result?.sourceUrl?.let { runCatching { android.net.Uri.parse(it).host }.getOrNull() }
        scope.launch {
            runCatching { ListsStore.create(kind, name.trim().take(60), formats[format], res.entries, host?.let { "Imported from $it" } ?: "Imported") }
                .onSuccess(onCreated)
                .onFailure { error = it.message }
            busy = false
        }
    }

    T1Screen {
        Bar(if (kind == ListKind.Deck) "Import deck" else "Import cube", subtitle = "From a link or a pasted list", onBack = onBack)
        error?.let { Notice(it, error = true) }
        val res = resolved
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (result == null || res == null) {
                item {
                    Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) {
                        T1TextField(link, { link = it }, label = if (kind == ListKind.Deck) "Link (ManaBox, Archidekt, MTGGoldfish…)" else "Cube Cobra link")
                    }
                }
                item {
                    Column(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Label("Or paste a list")
                        BasicTextField(text, { text = it }, Modifier.fillMaxWidth().heightIn(min = 160.dp),
                            textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 13.sp), cursorBrush = SolidColor(T1.accent))
                    }
                }
                item {
                    Notice(if (kind == ListKind.Deck) "Moxfield doesn't share decks with other apps: in Moxfield choose Export, copy the list as text and paste it here."
                           else "Cube Cobra: paste the cube's link. Any one-card-per-line list works too.")
                }
                item { BigAction(if (busy) "Reading…" else "Import", enabled = !busy && (link.isNotBlank() || text.isNotBlank()), busy = busy) { read() } }
            } else {
                val count = { b: String -> res.entries.filter { it.board == b }.sumOf { it.qty } }
                item { Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) { T1TextField(name, { name = it }, label = "Name") } }
                item { T1Segmented(formats.take(4), if (format < 4) format else -1) { format = it } }
                if (formats.size > 4) item { T1Segmented(formats.drop(4), if (format >= 4) format - 4 else -1) { format = it + 4 } }
                item {
                    val parts = if (kind == ListKind.Deck) listOf("${count("main")} main", if (count("side") > 0) "${count("side")} sideboard" else null,
                        if (count("maybe") > 0) "${count("maybe")} considering" else null, if (count("commander") > 0) "${count("commander")} commander" else null)
                    else listOf("${count("main")} cards", if (count("maybe") > 0) "${count("maybe")} considering" else null)
                    ListRow(parts.filterNotNull().joinToString(" · "), result?.sourceUrl?.let { android.net.Uri.parse(it).host })
                }
                if (res.missing.isNotEmpty()) item {
                    Notice("Not in the card data, left out: ${res.missing.take(12).joinToString(", ")}${if (res.missing.size > 12) " and ${res.missing.size - 12} more" else ""}", error = true)
                }
                item {
                    BigAction(if (kind == ListKind.Deck) "Create deck" else "Create cube", enabled = !busy && res.entries.isNotEmpty() && name.isNotBlank(), busy = busy) { create() }
                }
                item { ListRow("Start over", onClick = { result = null; resolved = null }) }
                for (b in CardList.BOARD_ORDER.filter { b -> res.entries.any { it.board == b } }) {
                    item(key = "s-$b") { Section(b.replaceFirstChar { it.uppercase() }.let { if (b == "maybe") "Considering" else if (b == "side") "Sideboard" else it }) }
                    items(res.entries.filter { it.board == b }, key = { "e-$b-${it.cardId}-${it.finish}" }) { e ->
                        val p = res.printings[e.cardId]
                        CardRow(p, res.names[e.cardId] ?: "", listOfNotNull(p?.setLabel, if (e.finish == "nonfoil") null else e.finish).joinToString(" · ")) {
                            Text("${e.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                        }
                    }
                }
            }
        }
    }
}
