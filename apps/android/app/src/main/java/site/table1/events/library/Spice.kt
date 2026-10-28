package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.util.UUID
import kotlin.math.roundToLong

/*
 * Spice (contract/spice-2026-10-28.md): how much of a deck or cube its peers rarely or never play. The server works it
 * out (list_spice); this decodes the answer, words it exactly as testdata/spice/cases.json says, and draws the Spice
 * section on the Stats screen and the Spice row of a shared deck or cube. Same as iOS Spice.swift and web spice.ts.
 */

@Serializable
data class SpiceResult(
    val kind: String,
    val score: Int? = null,
    val word: String? = null,
    val reason: String? = null,
    val basis: Basis? = null,
    val cards: List<Card> = emptyList(),
    @SerialName("stock_missing") val stockMissing: List<Missing> = emptyList(),
) {
    @Serializable
    data class Basis(
        val kind: String,
        val format: String? = null,
        val archetype: Int? = null,
        val name: String? = null,
        val lists: Int,
        val days: Int? = null,
        val sources: List<String> = emptyList(),
        val close: Boolean? = null,
        val cubes: List<Cube>? = null,
    )

    @Serializable
    data class Cube(val name: String, val overlap: Double)

    @Serializable
    data class Card(val c: String, val n: String, val section: String, val copies: Int, val rate: Double, val seen: Int, val of: Int)

    @Serializable
    data class Missing(val c: String, val n: String, val rate: Double, val seen: Int, val of: Int)
}

/** The words every client shows (the `display` of each case in testdata/spice/cases.json). */
object Spice {
    val WORDS = mapOf("stock" to "Stock", "tuned" to "Tuned", "spicy" to "Spicy", "brew" to "Brew")
    private val FORMATS = mapOf("standard" to "Standard", "pioneer" to "Pioneer", "modern" to "Modern", "pauper" to "Pauper",
        "canlander" to "Canadian Highlander", "legacy" to "Legacy")
    private val SOURCES = mapOf("mtgo" to "MTGO", "topdeck" to "TopDeck.gg", "cubecobra" to "Cube Cobra")
    private val REASONS = mapOf("empty" to "Add cards to see how spicy this is",
        "no_data" to "No tournament lists for this format yet",
        "no_cubes" to "No cubes to compare with yet")

    private fun plural(n: Int, one: String, many: String) = "$n ${if (n == 1) one else many}"

    /** The end of the Stats row: "Spice 34". */
    fun summary(r: SpiceResult) = r.score?.let { "Spice $it" }

    /** "34 · Spicy". */
    fun headline(r: SpiceResult): String? {
        val s = r.score ?: return null
        val w = r.word ?: return null
        return "$s · ${WORDS[w] ?: w}"
    }

    fun reason(r: SpiceResult) = if (r.score == null) REASONS[r.reason ?: ""] ?: REASONS["no_data"] else null

    /** What the deck or cube was compared with. */
    fun basis(r: SpiceResult): String? {
        val b = r.basis ?: return null
        if (r.score == null) return null
        val whenText = b.days?.let { if (it == 365) "last year" else "last $it days" } ?: ""
        val src = b.sources.joinToString(" and ") { SOURCES[it] ?: it }
        val fmt = b.format?.let { FORMATS[it] ?: it } ?: ""
        val name = b.name ?: ""
        return when (b.kind) {
            "archetype" -> "${plural(b.lists, "$name list", "$name lists")} · $whenText · $src"
            "closest" -> "Closest archetype: $name · ${plural(b.lists, "list", "lists")} · $whenText · $src"
            "format" -> "Nothing close in $fmt · ${plural(b.lists, "list", "lists")} · $whenText · $src"
            "colors" -> "$fmt lists that can play each card · ${plural(b.lists, "list", "lists")} · $whenText · $src"
            else -> "${if (b.close == true) "The ${b.lists} cubes most like yours" else "No cubes much like this one"} · $src"
        }
    }

    /** The nearest cubes: "LSVCube · 62% alike" (whole percent from the overlap's basis points, half up). */
    fun cubes(r: SpiceResult): List<String> =
        if (r.score == null) emptyList()
        else (r.basis?.cubes ?: emptyList()).map { "${it.name} · ${((it.overlap * 10000).roundToLong() + 50) / 100}% alike" }

    fun cardTitle(c: SpiceResult.Card) = "${c.copies} ${c.n}"

    /** "in 2 of 412 lists", "never seen", "in 3 of 40 lists that can play it", "in 3 of 20 similar cubes". */
    fun cardDetail(c: SpiceResult.Card, r: SpiceResult): String {
        val kind = r.basis?.kind
        val noun = when (kind) { "colors" -> "lists that can play it"; "cubes" -> "similar cubes"; else -> "lists" }
        val seen = if (c.seen == 0) (if (kind == "cubes") "in no similar cube" else "never seen") else "in ${c.seen} of ${c.of} $noun"
        return seen + if (c.section == "side") " · sideboard" else ""
    }

    fun cardLine(c: SpiceResult.Card, r: SpiceResult) = "${cardTitle(c)} · ${cardDetail(c, r)}"

    fun missingDetail(m: SpiceResult.Missing, r: SpiceResult) =
        "in ${m.seen} of ${m.of} ${if (r.basis?.kind == "cubes") "similar cubes" else "lists"}"

    fun missingLine(m: SpiceResult.Missing, r: SpiceResult) = "${m.n} · ${missingDetail(m, r)}"
}

/** By list id; [failed] holds lists whose last ask failed (offline, or no longer shared). */
data class SpiceState(val results: Map<String, SpiceResult> = emptyMap(), val failed: Set<String> = emptySet())

object SpiceStore {
    private val _state = MutableStateFlow(SpiceState())
    val state: StateFlow<SpiceState> = _state.asStateFlow()
    private val keys = mutableMapOf<String, String>()
    private val viewed = mutableSetOf<String>()

    /** Asks the server once per [key] (the list's cards: a change asks again); [token] when opened from a link. */
    suspend fun load(listId: String, key: String, token: String? = null) {
        if (keys[listId] == key && _state.value.results.containsKey(listId)) return
        keys[listId] = key
        runCatching {
            T1App.supabase.postgrest.rpc("list_spice", buildJsonObject {
                put("p_list_id", listId)
                if (token != null) put("p_token", token)
            }).decodeAs<SpiceResult>()
        }
            .onSuccess { r -> _state.update { it.copy(results = it.results + (listId to r), failed = it.failed - listId) } }
            .onFailure { keys.remove(listId); _state.update { it.copy(failed = it.failed + listId) } }
    }

    /** spice_viewed, once per list per screen open (the section passes its own open id). */
    fun viewed(r: SpiceResult, listId: String, open: String, format: String) {
        if (!viewed.add("$listId|$open")) return
        Telemetry.capture("spice_viewed", mapOf("kind" to r.kind, "format" to format, "basis" to (r.basis?.kind ?: r.reason ?: "none"),
            "word" to (r.word ?: "none")))
    }
}

/** Score and word, what it was compared with, the spiciest cards, stock cards you don't play. */
@Composable
fun SpiceSection(listId: String, kind: ListKind, format: String, logScreen: Boolean = true, onCard: (String) -> Unit) {
    val s by SpiceStore.state.collectAsState()
    val r = s.results[listId]
    var all by rememberSaveable { mutableStateOf(false) }
    val open = remember { UUID.randomUUID().toString() }
    LaunchedEffect(r) {
        if (r != null) {
            SpiceStore.viewed(r, listId, open, format)
            if (logScreen) Telemetry.screen(if (kind == ListKind.Cube) "cube_spice" else "deck_spice")
        }
    }
    fun opened(section: String, id: String) {
        Telemetry.capture("spice_card_opened", mapOf("kind" to (r?.kind ?: kind.name.lowercase()), "section" to section))
        onCard(id)
    }
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Section("Spice")
        val headline = r?.let(Spice::headline)
        when {
            r == null -> if (listId in s.failed) Notice("Spice isn't available right now") else ListRow("Reading spice…")
            headline == null -> Notice(Spice.reason(r) ?: "")
            else -> {
                Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(headline.uppercase(), color = T1.accent, fontFamily = T1.mono, fontSize = 24.sp, letterSpacing = 1.5.sp)
                    Spice.basis(r)?.let { Text(it, color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp, lineHeight = 18.sp) }
                    for (line in Spice.cubes(r)) Text(line, color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
                }
                if (r.cards.isNotEmpty()) {
                    Section("Spiciest cards")
                    for (c in if (all) r.cards else r.cards.take(8)) {
                        ListRow(Spice.cardTitle(c), Spice.cardDetail(c, r), onClick = { opened(c.section, c.c) })
                    }
                    if (r.cards.size > 8 && !all) ListRow("Show all ${r.cards.size}", onClick = { all = true })
                }
                if (r.stockMissing.isNotEmpty()) {
                    Section("Stock cards you don't play")
                    for (m in r.stockMissing) ListRow(m.n, Spice.missingDetail(m, r), onClick = { opened("missing", m.c) })
                }
            }
        }
    }
}

/** A shared deck or cube: a Spice row with the score, opening the section in place. */
@Composable
fun SpiceRow(listId: String, token: String?, kind: ListKind, format: String, onCard: (String) -> Unit) {
    val s by SpiceStore.state.collectAsState()
    var open by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(listId, token) { SpiceStore.load(listId, "shared", token) }
    val r = s.results[listId]
    val detail = r?.let { Spice.headline(it) ?: Spice.reason(it) } ?: if (listId in s.failed) "Not available" else "Reading spice…"
    ListRow("Spice", detail, onClick = { open = !open })
    if (open) SpiceSection(listId, kind, format, onCard = onCard)
}
