package site.table1.events.insights

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive

/** Insights packs and read RPCs (contract/insights-2026-10-24.md § Packs, § RPCs). Wire names as published. */
/**
 * What the viewer picked in Insights, kept on the account so every device opens the same way (user_settings.insights,
 * contract/insights-2026-10-24.md § What the viewer picked). Every key is optional; unknown keys are kept as they were.
 */
@kotlinx.serialization.Serializable
data class InsightsPicks(
    val section: String? = null, val format: String? = null, val tier: String? = null, val days: Int? = null,
    val set: String? = null, val event: String? = null, val group: String? = null,
    @kotlinx.serialization.SerialName("hidden_formats") val hiddenFormats: List<String>? = null,
    @kotlinx.serialization.SerialName("hidden_sets") val hiddenSets: List<String>? = null,
) {
    companion object {
        private val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true; explicitNulls = false }

        fun read(o: kotlinx.serialization.json.JsonObject): InsightsPicks = runCatching { json.decodeFromJsonElement(serializer(), o) }.getOrDefault(InsightsPicks())

        /** The object to store: [p]'s keys over what the account already holds (keys from newer clients stay). */
        fun write(p: InsightsPicks, held: kotlinx.serialization.json.JsonObject?): kotlinx.serialization.json.JsonObject =
            kotlinx.serialization.json.JsonObject((held ?: emptyMap()) + json.encodeToJsonElement(serializer(), p) as kotlinx.serialization.json.JsonObject)
    }
}

object Insights {
    /** Which pack to load first: the one on screen (the picked format, or on Limited the picked set or else the first), then its section's, then the rest. */
    fun packOrder(index: List<IndexEntry>, section: String, format: String, setCode: String?): List<IndexEntry> {
        val first = if (section == "limited") (setCode?.let { s -> index.firstOrNull { it.kind == "limited" && it.key == s } } ?: index.firstOrNull { it.kind == "limited" })
            else index.firstOrNull { it.kind == "constructed" && it.key == format }
        return listOfNotNull(first) + index.filter { it != first && it.kind == first?.kind } + index.filter { it.kind != first?.kind }
    }

    val windows = listOf(7, 14, 30, 90)
    val formats = listOf("standard" to "Standard", "pioneer" to "Pioneer", "modern" to "Modern", "legacy" to "Legacy", "vintage" to "Vintage",
        "pauper" to "Pauper", "canlander" to "Canlander")

    /** The options a picker shows: every one not hidden, in order (all of them if every one is hidden). */
    fun visibleKeys(all: List<String>, hidden: List<String>): List<String> = all.filter { it !in hidden }.ifEmpty { all }
    /** Whether an option may be hidden: at least one other has to stay shown. */
    fun canHide(all: List<String>, hidden: List<String>, key: String): Boolean = all.any { it != key && it !in hidden }

    /** The deck page's example list: from the biggest event (major, large, regular, small), the best finish there,
     *  then the newest; only whole lists (40+ main deck cards). Null when there's none. */
    fun exampleFinish(finishes: List<ArchetypePage.Finish>): Int? {
        val order = listOf("major", "large", "regular", "small")
        fun tier(f: ArchetypePage.Finish) = order.indexOf(f.tier).let { if (it < 0) order.size else it }
        fun rank(f: ArchetypePage.Finish) = f.rank ?: Int.MAX_VALUE
        var best: Int? = null
        finishes.forEachIndexed { i, f ->
            if (f.main.sumOf { it.qty } < 40) return@forEachIndexed
            val b = best?.let { finishes[it] }
            if (b == null || tier(f) < tier(b) || (tier(f) == tier(b) && (rank(f) < rank(b) || (rank(f) == rank(b) && f.on > b.on)))) best = i
        }
        return best
    }
    /** "1st", "2nd", "3rd", "4th"…: a finish's place. */
    fun place(rank: Int): String {
        val t = rank % 100; val u = rank % 10
        return "$rank" + if (t in 11..13) "th" else when (u) { 1 -> "st"; 2 -> "nd"; 3 -> "rd"; else -> "th" }
    }

    /** The studies' heading: a points format's changes are points changes, not bans. */
    fun bansTitle(kinds: List<String>): String = if (kinds.isNotEmpty() && kinds.all { it == "points" }) "Points changes" else "Bans and unbans"

    /** One row of the format page: a part that opens on its own screen. */
    data class Part(val key: String, val title: String, val detail: String)

    /** The format page's parts behind a row each (contract/insights-2026-10-24.md § Format page): key, title and a
     *  one-line summary for the picked tier and window; parts with nothing to show are left out. Shared cases in
     *  testdata/insights/parts.json. */
    fun formatParts(p: ConstructedPack, tier: String, days: Int): List<Part> {
        val view = p.tiers[tier]
        val w = view?.windows?.get(days.toString())
        val out = mutableListOf<Part>()
        if (w != null && w.share.isNotEmpty()) {
            val named = w.share.filter { it.a != 0 }
            out += Part("meta", "Meta now", listOfNotNull(named.firstOrNull()?.let { "${p.name(it.a)} ${InsightCharts.pct(it.share)}" },
                "${named.size} archetypes").joinToString(" · "))
        }
        if (w != null) {
            val up = w.cards["main"]?.up?.firstOrNull()
            out += Part("cards", "Cards rising and falling",
                up?.let { "Rising most: ${it.n} ▲ ${InsightCharts.delta(it.rate - (it.prev ?: 0.0)).drop(1)}" } ?: "No card moved much in this window")
        }
        view?.new_set?.let { ns ->
            ns.cards.firstOrNull()?.let { top -> out += Part("new_set", "New set · ${ns.name}", "${ns.cards.size} cards played · ${top.n} in ${InsightCharts.pct(top.rate)}") }
        }
        val studied = p.bans.mapNotNull { p.change(it.change) }
        if (studied.isNotEmpty()) {
            val latest = studied.reduce { a, c -> if (c.on > a.on) c else a }
            out += Part("changes", bansTitle(studied.map { it.kind }),
                "${latest.words} · ${InsightCharts.shortDay(latest.on)}" + if (studied.size > 1) " · ${studied.size - 1} more" else "")
        }
        val events = p.events.filter { tier == "all" || it.tier == "major" || it.tier == "large" }
        if (events.isNotEmpty()) {
            val latest = events.reduce { a, e -> if (e.on > a.on) e else a }
            out += Part("events", if (tier == "big") "Big events" else "Events", "${events.size} ${if (events.size == 1) "event" else "events"} · latest ${latest.name}")
        }
        return out
    }

    /** "A", "A and B", "A, B and C". */
    fun andList(xs: List<String>): String =
        if (xs.size < 2) xs.joinToString("") else xs.dropLast(1).joinToString(", ") + " and " + xs.last()

    private val sourceNames = listOf(Triple("mtgo", "Magic Online", "https://www.mtgo.com/decklists"),
        Triple("topdeck", "TopDeck.gg", "https://topdeck.gg"), Triple("melee", "Melee", "https://melee.gg"))

    /** The credit under a constructed brief, from the pack's sources in a fixed order: TopDeck.gg asks for a visible
     *  credit and link whenever its data is shown, so the link is TopDeck's when it's a source; Canadian Highlander
     *  comes from TopDeck alone. Melee results come through the MTG_decklistcache. */
    fun sourcesCredit(sources: List<String>): Pair<String, String> {
        val named = sourceNames.filter { it.first in sources }
        if (named.isEmpty()) return "Results from Magic Online" to sourceNames[0].third
        val link = named.firstOrNull { it.first == "topdeck" } ?: named[0]
        return "Results from ${andList(named.map { it.second })}" to link.third
    }
    val eventOrder = listOf("PremierDraft", "TradDraft", "PickTwoDraft", "Sealed", "TradSealed")
    val eventLabels = mapOf("PremierDraft" to "Premier", "TradDraft" to "Traditional", "PickTwoDraft" to "Pick Two", "Sealed" to "Sealed", "TradSealed" to "Trad Sealed")
    val pairNames = mapOf("WU" to "Azorius", "WB" to "Orzhov", "WR" to "Boros", "WG" to "Selesnya", "UB" to "Dimir", "UR" to "Izzet", "UG" to "Simic",
        "BR" to "Rakdos", "BG" to "Golgari", "RG" to "Gruul", "W" to "Mono-White", "U" to "Mono-Blue", "B" to "Mono-Black", "R" to "Mono-Red",
        "G" to "Mono-Green", "3C" to "Three or more", "C" to "Colorless")
    private val shards = mapOf("WUB" to "Esper", "UBR" to "Grixis", "BRG" to "Jund", "WRG" to "Naya", "WUG" to "Bant", "WBG" to "Abzan", "WUR" to "Jeskai",
        "UBG" to "Sultai", "WBR" to "Mardu", "URG" to "Temur")

    /** "Dimir UB + r", "Esper WUB", "Four-color WUBR": a deck's colors as 17Lands' deck color table names them. */
    fun colorsName(m: String, s: String): String {
        val base = when (m.length) { 0, 1, 2 -> pairNames[m] ?: m; 3 -> shards[m] ?: "Three-color"; 4 -> "Four-color"; else -> "Five-color" }
        return "$base $m" + if (s.isEmpty()) "" else " + ${s.lowercase()}"
    }
}

@Serializable data class IndexEntry(val kind: String, val key: String, val name: String, val version: String, val url: String, val bytes: Int = 0, val through: String? = null)

@Serializable data class Archetype(val id: Int, val name: String, val family: String, val colors: String)
@Serializable data class Change(val id: Int, val on: String, val kind: String, val cards: List<String>, val set_code: String? = null, val note: String? = null, val url: String? = null) {
    val words: String get() {
        val c = if (cards.size > 3) cards.take(3).joinToString(", ") + " and others" else cards.joinToString(" and ")
        return when (kind) {
            "ban" -> "Banned: $c"; "unban" -> "Unbanned: $c"; "restrict" -> "Restricted: $c"; "unrestrict" -> "Unrestricted: $c"
            "rotation" -> "Rotation"
            "points" -> "Points: ${note ?: c}"
            else -> "Released: ${note ?: set_code?.uppercase() ?: "a new set"}"
        }
    }
    /** Changes with a before/after study: bans and their kin, and Canadian Highlander's points changes. */
    val isBan: Boolean get() = kind in setOf("ban", "unban", "restrict", "unrestrict", "points")
}
/** `wr`, `t8r`, `won` and the window's `won_of` are missing from packs built before 2026-10-28. */
@Serializable data class ShareRow(val a: Int, val share: Double, val prev: Double? = null, val decks: Int, val top8: Int, val conv: Double? = null,
                                  val wr: Double? = null, val t8r: Double? = null, val won: Int? = null)
@Serializable data class CardRow(val c: String, val n: String, val rate: Double, val prev: Double? = null, val copies: Double? = null)
@Serializable data class Movers(val up: List<CardRow>, val down: List<CardRow>)
@Serializable data class Window(val decks: Int, val weighted: Double, val events: Int, val thin: Boolean, val brief: String? = null,
                                val share: List<ShareRow>, val cards: Map<String, Movers>, val won_of: Int? = null,
                                /** this tier × window's matchup grid (packs from 20261030090000 on) */
                                val matchups: Matchups? = null)
@Serializable data class Line(val a: Int, val v: List<Double?>)
@Serializable data class Series(val from: String, val days: Int, val lines: List<Line>, val other: List<Double?>)
@Serializable data class NewSetCard(val c: String, val n: String, val rate: Double, val copies: Double? = null, val `in`: List<Int>? = null)
@Serializable data class NewSet(val set_code: String, val name: String, val released: String, val cards: List<NewSetCard>)
@Serializable data class View(val windows: Map<String, Window>, val series: Series, val new_set: NewSet? = null)
@Serializable data class Move(val a: Int, val before: Double, val after: Double)
@Serializable data class Replacement(val c: String, val n: String, val before: Double, val after: Double, val `in`: Int)
@Serializable data class AShare(val a: Int, val share: Double)
@Serializable data class BanStudy(val change: Int, val on: String, val before: List<AShare>, val after: Map<String, List<AShare>>,
                                  val losers: List<Move>, val gainers: List<Move>, val replacements: List<Replacement>,
                                  val settled_days: Int? = null, val brief: String? = null) {
    /** The longest "after" window that has ended (60 → 30 → 14 days). */
    val afterWindow: Pair<Int, List<AShare>>? get() = listOf(60, 30, 14).firstNotNullOfOrNull { d -> after[d.toString()]?.let { d to it } }
}
/** [archetypes] are the grid's columns (top 10); [rows] every discernible archetype, the columns first, Other last
 *  (missing from packs before 20261030090000). */
@Serializable data class Matchups(val archetypes: List<Int>, val cells: List<List<Int>>, val rows: List<Int>? = null) {
    /** The grid's rows: every discernible archetype, or the columns in an older pack. */
    val rowIds: List<Int> get() = rows?.takeIf { it.isNotEmpty() } ?: archetypes
    /** [a] against [b]: wins, losses, draws from a's side. */
    fun cell(a: Int, b: Int): Triple<Int, Int, Int>? {
        cells.firstOrNull { it[0] == a && it[1] == b }?.let { return Triple(it[2], it[3], it[4]) }
        cells.firstOrNull { it[0] == b && it[1] == a }?.let { return Triple(it[3], it[2], it[4]) }
        return null
    }
}
/** What `insights_mine` says about the signed-in account in a format: its decks with their archetypes, and how much of
 *  each archetype's usual list its collection holds. */
@Serializable data class Mine(val decks: List<MineDeck>, val coverage: List<MineCover>)
@Serializable data class MineDeck(val a: Int, val id: String, val name: String)
@Serializable data class MineCover(val a: Int, val have: Double)
/** Collection coverage from which an archetype counts as nearly yours. */
const val CLOSE = 0.6
/** The grid's rows with your decks first, then archetypes your collection nearly builds, each with its note
 *  (testdata/insights/yours-first.json). */
fun yoursFirst(rows: List<Int>, mine: Mine?): List<Pair<Int, String?>> {
    if (mine == null) return rows.map { it to null }
    val decks = mine.decks.filter { it.a != 0 }.groupingBy { it.a }.eachCount()
    val have = mine.coverage.filter { it.a != 0 }.associate { it.a to it.have }
    val own = rows.filter { it in decks }
    val close = rows.filter { it !in decks && (have[it] ?: 0.0) >= CLOSE }
        .sortedWith(compareByDescending<Int> { have[it]!! }.thenBy { rows.indexOf(it) })
    val rest = rows.filter { it !in own && it !in close }
    return own.map { it to (if (decks[it]!! > 1) "Your ${decks[it]} decks" else "Your deck") } +
        close.map { it to "You have ${kotlin.math.floor(have[it]!! * 100 + 1e-9).toInt()}%" } +
        rest.map { it to null }
}
// a deck's archetype, on the deck's own screen (list_insight)
@Serializable data class Record3(val wins: Int, val losses: Int, val draws: Int)
@Serializable data class DeckMatchup(val vs: Int, val name: String, val wins: Int, val losses: Int, val draws: Int)
@Serializable data class DeckInsightAnswer(val format: String, val a: Int? = null, val name: String? = null, val reason: String? = null,
                                           val month: Record3? = null, val week: Record3? = null, val prev: Record3? = null,
                                           val matchups: List<DeckMatchup>? = null)
data class DeckInsight(val title: String?, val win: String?, val change: String?, val good: List<String>, val bad: List<String>, val note: String?)
/** Matches a rate needs before it's shown. */
const val DECK_MIN = 20
/** How a deck screen words its archetype's numbers (testdata/insights/deck-insight.json). */
fun deckInsight(r: DeckInsightAnswer): DeckInsight {
    if (r.reason == "other" || r.a == 0) return DeckInsight(null, null, null, emptyList(), emptyList(), "Doesn't match an archetype Insights knows")
    if (r.a == null || r.name == null) return DeckInsight(null, null, null, emptyList(), emptyList(), null)
    fun rate(x: Record3?): Double? {
        val n = x?.let { it.wins + it.losses + it.draws } ?: 0
        return if (x != null && n >= DECK_MIN) x.wins.toDouble() / n else null
    }
    val w = rate(r.week); val p = rate(r.prev)
    val change = if (w != null && p != null) {
        val d = (w - p) * 100
        if (kotlin.math.abs(d) < 0.05) "Same as last week"
        else "${if (d > 0) "▲" else "▼"} ${String.format(java.util.Locale.US, "%.1f", kotlin.math.abs(d))} pts on last week"
    } else null
    data class Rated(val name: String, val wr: Double, val n: Int)
    val rated = (r.matchups ?: emptyList()).filter { it.wins + it.losses >= DECK_MIN }
        .map { Rated(it.name, it.wins.toDouble() / (it.wins + it.losses), it.wins + it.losses) }
    val good = rated.filter { it.wr > 0.5 }.sortedWith(compareByDescending<Rated> { it.wr }.thenByDescending { it.n }).take(3)
    val bad = rated.filter { it.wr < 0.5 }.sortedWith(compareBy<Rated> { it.wr }.thenByDescending { it.n }).take(3)
    return DeckInsight(r.name, rate(r.month)?.let { "Win ${InsightCharts.pct1(it)}" }, change,
        good.map { "${it.name} ${InsightCharts.pct(it.wr)}" }, bad.map { "${it.name} ${InsightCharts.pct(it.wr)}" }, null)
}
@Serializable data class EventRow(val name: String, val on: String, val players: Int? = null, val tier: String, val source: String, val url: String? = null,
                                  val top8: List<Int>? = null, val winner: Int? = null)
@Serializable data class ConstructedPack(val format: String, val name: String, val through: String, val sources: List<String>, val default_tier: String,
                                         val archetypes: List<Archetype>, val changes: List<Change>, val events: List<EventRow>,
                                         val tiers: Map<String, View>, val bans: List<BanStudy>, val matchups: Matchups) {
    /** The matchup grid for the picked tier and window, and what it covers; an older pack has only its 90-day, All events grid. */
    fun grid(tier: String, days: Int): Pair<Matchups, String> =
        tiers[tier]?.windows?.get(days.toString())?.matchups?.let { it to "${if (tier == "big") "Big events" else "All events"}, last $days days" }
            ?: (matchups to "All events, last 90 days")
    fun name(id: Int) = archetypes.firstOrNull { it.id == id }?.name ?: "Other"
    fun change(id: Int) = changes.firstOrNull { it.id == id }
}

/** [name, copies] */
@Serializable(with = DeckLineSerializer::class) data class DeckLine(val name: String, val qty: Int)
object DeckLineSerializer : KSerializer<DeckLine> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("DeckLine")
    override fun deserialize(decoder: Decoder): DeckLine {
        val a = (decoder as JsonDecoder).decodeJsonElement() as JsonArray
        return DeckLine(a[0].jsonPrimitive.content, a[1].jsonPrimitive.int)
    }
    override fun serialize(encoder: Encoder, value: DeckLine) = throw UnsupportedOperationException()
}

@Serializable data class ArchetypePage(
    val archetype: Archetype, val decks: Int, val series: Weekly, val record: Record? = null, val conv: Double? = null,
    val core: List<CardRow>, val flex: List<CardRow>, val side: List<CardRow>, val matchups: List<Matchup>, val finishes: List<Finish>, val brief: String? = null,
    /** Other (archetype 0) only: its decks by colors, each with its most-played cards and its example in [finishes]. */
    val groups: List<Group>? = null,
) {
    @Serializable data class Group(val colors: String, val decks: Int, val share: Double, val cards: List<String>, val example: Int? = null)
    @Serializable data class Weekly(val from: String, val weeks: Int, val v: List<Double?>)
    @Serializable data class Record(val wins: Int, val losses: Int, val draws: Int, val basis: String)
    @Serializable data class Matchup(val vs: Int, val wins: Int, val losses: Int, val draws: Int)
    @Serializable data class Finish(val event: String, val on: String, val players: Int? = null, val tier: String, val rank: Int? = null, val url: String? = null,
                                    val main: List<DeckLine>, val side: List<DeckLine>)
}
@Serializable data class CardPage(val c: String, val n: String? = null, val series: Weekly, val copies: Double? = null, val by_archetype: List<ByArchetype>,
                                  val first_seen: String? = null) {
    @Serializable data class Weekly(val from: String, val weeks: Int, val main: List<Double?>, val side: List<Double?>)
    @Serializable data class ByArchetype(val a: Int, val rate: Double, val copies: Double? = null)
}

@Serializable data class LCard(val c: String? = null, val n: String, val r: String? = null, val col: String? = null,
                               val gih: Double? = null, val gih_n: Int, val oh: Double? = null, val gd: Double? = null, val gns: Double? = null, val iwd: Double? = null,
                               val ata: Double? = null, val deck: Double, val week_gih: List<Double?>? = null, val pair_gih: Map<String, Double>? = null)
@Serializable data class LPair(val p: String, val games: Int, val wr: Double, val share: Double, val splash: Double, val play_wr: Double? = null,
                               val draw_wr: Double? = null, val week_wr: List<Double?>, val week_share: List<Double?>)
@Serializable data class LFacts(val play_wr: Double? = null, val draw_wr: Double? = null, val mull_rate: Double? = null, val mull_wr: Double? = null,
                                val keep7_wr: Double? = null, val mull_play: Double? = null, val turns: Double? = null)
/** One exact color combination: main colors (WUBRG order, as 17Lands writes them) and the splash ("" for none). */
@Serializable data class LColors(val m: String, val s: String, val games: Int, val wr: Double, val share: Double)
@Serializable data class LView(val games: Int, val wr: Double, val weeks: Int, val brief: String? = null, val pairs: List<LPair>, val cards: List<LCard>, val facts: LFacts,
                               val colors: List<LColors> = emptyList())
@Serializable data class LEvent(val updated: String, val groups: Map<String, LView>)
@Serializable data class Credit(val name: String, val url: String)
@Serializable data class LimitedPack(val set_code: String, val name: String? = null, val released: String? = null, val credit: Credit, val events: Map<String, LEvent>,
                                     /** An Arena cube version's family (contract/insights-2026-10-24.md § Arena cubes); null for a set. */
                                     val cube: CubeFamily? = null)
@Serializable data class CubeFamily(val family: String, val name: String)
