package site.table1.events.library

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
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
import androidx.compose.runtime.DisposableEffect
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import site.table1.events.util.Push
import site.table1.events.util.Telemetry
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
// paper printing. Same flow as iOS and the web. The search runs on the server as a job (contract § Jobs): the
// screen polls it, the phone can be locked, and a `deck.found` push brings the player back to it.

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
        /** table1 (Table 1's own results) or web; older answers have none. */
        val from: String? = null,
        val main: List<Line> = emptyList(), val side: List<Line> = emptyList(),
    )
}

private val FINDER_FORMATS = listOf("modern", "pioneer", "standard", "legacy", "vintage", "pauper", "commander", "premodern")

/** [jobId]: a job to open (a tapped `deck.found` push); null starts fresh and picks up the newest job when it's recent. */
@Composable
fun DeckFinderScreen(onBack: () -> Unit, onCreated: (String) -> Unit, jobId: String? = null) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val cat by CatalogStore.state.collectAsState()
    var query by remember { mutableStateOf("") }
    var format by remember { mutableStateOf(0) }
    var answers by remember { mutableStateOf(listOf<FinderAnswer>()) }
    /** The job under way or last shown; polled while it runs. */
    var job by remember { mutableStateOf(jobId) }
    var searching by remember { mutableStateOf(jobId != null) }
    /** The agent's work so far, shown while it runs (contract § Jobs "Show the work"). */
    var steps by remember { mutableStateOf(listOf<String>()) }
    var result by remember { mutableStateOf<FinderResult?>(null) }
    var reply by remember { mutableStateOf("") }
    var creating by remember { mutableStateOf(false) }
    var resolved by remember { mutableStateOf<Map<String, CatalogPrinting>>(emptyMap()) }
    var resumed by remember { mutableStateOf(if (jobId != null) "push" else null) }
    val deck = result?.deck?.takeIf { result?.status == "deck" }
    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    LaunchedEffect(deck, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val names = deck?.let { (it.main + it.side).map { l -> l.name } } ?: return@LaunchedEffect
        resolved = withContext(Dispatchers.Default) { db.printingsByName(names) }
    }

    fun pickFormat(f: String?) { f?.let { FINDER_FORMATS.indexOf(it).takeIf { i -> i >= 0 } }?.let { format = it } }
    fun show(r: FinderResult) {
        pickFormat(r.deck?.format)
        if (r.status != "question") Telemetry.capture("deck_finder_used", mapOf("found" to (r.deck != null), "from" to (r.deck?.from ?: ""), "resumed" to (resumed ?: "")))
        result = r
        searching = false
        Push.quietDeckJob = null
    }
    // Opening with no job of its own: the account's newest job when it's still running or just finished.
    LaunchedEffect(Unit) {
        if (job != null) return@LaunchedEffect
        val j = runCatching { DeckFinderJobs.job(null) }.getOrNull() ?: return@LaunchedEffect
        if (!DeckFinderJobs.resume(j)) return@LaunchedEffect
        resumed = "open"
        query = j.query; pickFormat(j.format); answers = j.answers; steps = j.steps
        if (j.finished) show(DeckFinderJobs.resultOf(j)) else { searching = true; job = j.job_id }
    }
    // Asks after the job every few seconds until it's finished (errors, offline too, just wait for the next ask).
    LaunchedEffect(job) {
        val id = job ?: return@LaunchedEffect
        Push.quietDeckJob = id
        while (true) {
            val j = runCatching { DeckFinderJobs.job(id) }.getOrNull()
            if (j != null) {
                if (query.isEmpty()) { query = j.query; pickFormat(j.format); answers = j.answers }
                if (j.steps != steps) steps = j.steps
                if (j.finished) { show(DeckFinderJobs.resultOf(j)); return@LaunchedEffect }
            }
            delay(DeckFinderJobs.POLL_MS)
        }
    }
    DisposableEffect(Unit) { onDispose { if (Push.quietDeckJob == job) Push.quietDeckJob = null } }

    fun search(with: List<FinderAnswer>) {
        searching = true
        result = null
        steps = emptyList()
        scope.launch {
            runCatching { DeckFinderJobs.start(query.trim(), FINDER_FORMATS[format], with) }
                .onSuccess { resumed = null; job = it }
                .onFailure { e -> searching = false; result = FinderResult(status = "error", message = DeckFinderJobs.words(e)) }
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
            if (searching) {
                item { Notice("Searching Table 1's results, mtgdecks, melee.gg, MTGGoldfish and MTGO for the newest strong finishes. This can take a minute or two: you can lock your phone or leave this screen, and you'll get a notification when it's done.") }
                if (steps.isNotEmpty()) item { Section("Working") }
                itemsIndexed(steps) { i, step -> ListRow(step, if (i == steps.lastIndex) "…" else null) }
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
                    item { ListRow(deck.name, DeckFinderJobs.headline(deck.placement, deck.event, deck.date)) }
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
                else -> {
                    item { Notice(r.message ?: "Nothing turned up. Try naming the archetype.", error = true) }
                    item { ListRow("Search again", onClick = { result = null }) }
                }
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
