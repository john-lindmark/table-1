package site.table1.events.library

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.background
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
import androidx.compose.ui.platform.LocalContext
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
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1

// Deck finder (contract/deck-finder-2026-10-15.md): describe a deck in plain words; an agent finds a recent
// tournament list, asks when the request is ambiguous, and the list is created with each card's original
// paper printing. Same flow as iOS and the web.

@Serializable
data class FinderResult(
    val status: String = "error",
    val question: String? = null,
    val options: List<String> = emptyList(),
    val message: String? = null,
    val error: String? = null,
    val deck: FoundDeck? = null,
) {
    @Serializable
    data class Line(val qty: Int, val name: String)

    @Serializable
    data class FoundDeck(
        val name: String = "", val archetype: String = "", val format: String = "", val event: String = "",
        val date: String = "", val placement: String = "", val player: String = "",
        @SerialName("source_url") val sourceUrl: String = "", val notes: String = "",
        val main: List<Line> = emptyList(), val side: List<Line> = emptyList(),
    )
}

private data class FinderAnswer(val question: String, val answer: String)

private val FINDER_FORMATS = listOf("modern", "pioneer", "standard", "legacy", "vintage", "pauper", "commander", "premodern")

/** One search. The function streams spaces while it works, so the request gets a long timeout. */
private suspend fun findDeck(query: String, format: String, answers: List<FinderAnswer>): FinderResult = try {
    val response = T1App.supabase.functions.invoke("deck-finder") {
        contentType(ContentType.Application.Json)
        setBody(buildJsonObject {
            put("query", query); put("format", format)
            putJsonArray("answers") { answers.forEach { a -> addJsonObject { put("question", a.question); put("answer", a.answer) } } }
        }.toString())
        timeout { requestTimeoutMillis = 170_000; socketTimeoutMillis = 60_000 }
    }
    val r = T1App.json.decodeFromString<FinderResult>(response.bodyAsText().trim())
    if (r.error != null) r.copy(status = "error", message = r.error) else r
} catch (e: Exception) {
    // A refusal (sign in, daily allowance) carries the server's own message.
    val msg = e.message?.let { m -> Regex("\"error\"\\s*:\\s*\"([^\"]+)\"").find(m)?.groupValues?.get(1) }
    FinderResult(status = "error", message = msg ?: "The deck finder couldn't search just now. Try again.")
}

@Composable
fun DeckFinderScreen(onBack: () -> Unit, onCreated: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val cat by CatalogStore.state.collectAsState()
    var query by remember { mutableStateOf("") }
    var format by remember { mutableStateOf(0) }
    var answers by remember { mutableStateOf(listOf<FinderAnswer>()) }
    var searching by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<FinderResult?>(null) }
    var reply by remember { mutableStateOf("") }
    var creating by remember { mutableStateOf(false) }
    var resolved by remember { mutableStateOf<Map<String, CatalogPrinting>>(emptyMap()) }
    val deck = result?.deck?.takeIf { result?.status == "deck" }
    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    LaunchedEffect(deck, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val names = deck?.let { (it.main + it.side).map { l -> l.name } } ?: return@LaunchedEffect
        resolved = withContext(Dispatchers.Default) { db.printingsByName(names) }
    }

    fun search(with: List<FinderAnswer>) {
        searching = true
        scope.launch {
            val r = findDeck(query.trim(), FINDER_FORMATS[format], with)
            r.deck?.format?.let { f -> FINDER_FORMATS.indexOf(f).takeIf { it >= 0 }?.let { format = it } }
            result = r
            searching = false
        }
    }
    fun answer(text: String) {
        val q = result?.question ?: return
        if (text.isBlank()) return
        answers = answers + FinderAnswer(q, text.trim())
        reply = ""
        search(answers)
    }
    fun create(d: FinderResult.FoundDeck) {
        creating = true
        val entries = LinkedHashMap<String, ListEntry>()
        for ((board, lines) in listOf("main" to d.main, "side" to d.side)) {
            for (l in lines) {
                val p = resolved[l.name] ?: continue
                val k = "$board|${p.cardId}"
                entries[k] = entries[k]?.let { it.copy(qty = it.qty + l.qty) } ?: ListEntry(p.cardId, board, l.qty)
            }
        }
        val source = listOf(d.placement, d.event, d.date).filter { it.isNotBlank() }.joinToString(", ")
        scope.launch {
            runCatching {
                ListsStore.create(ListKind.Deck, d.name.take(60), FINDER_FORMATS[format], entries.values.toList(),
                    if (source.isEmpty()) "Found online" else "Found: $source".take(120), "finder")
            }.onSuccess(onCreated)
            creating = false
        }
    }

    T1Screen {
        Bar("Find a deck", subtitle = "Recent tournament lists", onBack = onBack)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item {
                Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) {
                    T1TextField(query, { query = it }, label = "Describe the deck")
                }
            }
            item { T1Segmented(FINDER_FORMATS.take(4), if (format < 4) format else -1) { format = it } }
            item { T1Segmented(FINDER_FORMATS.drop(4), if (format >= 4) format - 4 else -1) { format = it + 4 } }
            if (deck == null) item {
                BigAction(if (searching) "Searching…" else "Find deck", enabled = !searching && query.trim().length >= 3, busy = searching) {
                    answers = emptyList(); search(emptyList())
                }
            }
            if (searching) item {
                Notice("Searching mtgdecks, melee.gg, MTGGoldfish and MTGO results for the newest strong finishes. This can take a minute or two.")
            }
            val r = result
            if (!searching && r != null) when {
                r.status == "question" -> {
                    item { Section(r.question ?: "Which deck?") }
                    items(r.options) { o -> ListRow(o, onClick = { answer(o) }) }
                    item { Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) { T1TextField(reply, { reply = it }, label = "Or type an answer") } }
                    item { BigAction("Answer", enabled = reply.isNotBlank()) { answer(reply) } }
                }
                deck != null -> {
                    val main = deck.main.sumOf { it.qty }; val side = deck.side.sumOf { it.qty }
                    val missing = (deck.main + deck.side).map { it.name }.filter { it !in resolved }.distinct().sorted()
                    item { ListRow(deck.name, listOf(deck.placement, deck.event, deck.date).filter { it.isNotBlank() }.joinToString(" · ")) }
                    if (deck.player.isNotBlank() || deck.notes.isNotBlank()) item {
                        Notice(listOfNotNull(deck.player.takeIf { it.isNotBlank() }?.let { "Played by $it." }, deck.notes.takeIf { it.isNotBlank() }).joinToString(" "))
                    }
                    if (deck.sourceUrl.startsWith("http")) item {
                        ListRow("Source", Uri.parse(deck.sourceUrl).host ?: deck.sourceUrl, onClick = {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(deck.sourceUrl)))
                        })
                    }
                    if (missing.isNotEmpty()) item { Notice("Not in the card data, left out: ${missing.joinToString(", ")}", error = true) }
                    item { BigAction("Create deck · $main + $side", enabled = !creating && resolved.isNotEmpty(), busy = creating) { create(deck) } }
                    item { ListRow("Search again", onClick = { result = null }) }
                    item { Section("Main deck · $main") }
                    items(deck.main) { l -> FinderLine(l, resolved[l.name]) }
                    if (deck.side.isNotEmpty()) item { Section("Sideboard · $side") }
                    items(deck.side) { l -> FinderLine(l, resolved[l.name]) }
                }
                else -> item { Notice(r.message ?: "Nothing turned up. Try naming the archetype.", error = true) }
            }
        }
    }
}

@Composable
private fun FinderLine(l: FinderResult.Line, p: CatalogPrinting?) {
    CardRow(p, l.name, if (p == null) "Not found" else null) {
        Text("${l.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
    }
}
