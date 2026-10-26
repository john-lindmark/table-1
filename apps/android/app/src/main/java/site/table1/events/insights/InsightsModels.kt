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
object Insights {
    val windows = listOf(7, 14, 30, 90)
    val formats = listOf("standard" to "Standard", "pioneer" to "Pioneer", "modern" to "Modern", "pauper" to "Pauper", "canlander" to "Canlander")

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

    /** The credit under a constructed brief, from the pack's sources: TopDeck.gg asks for a visible credit and link
     *  whenever its data is shown; Canadian Highlander comes from TopDeck alone. */
    fun sourcesCredit(sources: List<String>): Pair<String, String> {
        val mtgo = "mtgo" in sources
        val td = "topdeck" in sources
        return when {
            td && !mtgo -> "Results from TopDeck.gg" to "https://topdeck.gg"
            td -> "Results from Magic Online and TopDeck.gg" to "https://topdeck.gg"
            else -> "Results from Magic Online" to "https://www.mtgo.com/decklists"
        }
    }
    val eventOrder = listOf("PremierDraft", "TradDraft", "PickTwoDraft", "Sealed", "TradSealed")
    val eventLabels = mapOf("PremierDraft" to "Premier", "TradDraft" to "Traditional", "PickTwoDraft" to "Pick Two", "Sealed" to "Sealed", "TradSealed" to "Trad Sealed")
    val pairNames = mapOf("WU" to "Azorius", "WB" to "Orzhov", "WR" to "Boros", "WG" to "Selesnya", "UB" to "Dimir", "UR" to "Izzet", "UG" to "Simic",
        "BR" to "Rakdos", "BG" to "Golgari", "RG" to "Gruul", "W" to "Mono-White", "U" to "Mono-Blue", "B" to "Mono-Black", "R" to "Mono-Red",
        "G" to "Mono-Green", "3C" to "Three or more", "C" to "Colourless")
    private val shards = mapOf("WUB" to "Esper", "UBR" to "Grixis", "BRG" to "Jund", "WRG" to "Naya", "WUG" to "Bant", "WBG" to "Abzan", "WUR" to "Jeskai",
        "UBG" to "Sultai", "WBR" to "Mardu", "URG" to "Temur")

    /** "Dimir UB + r", "Esper WUB", "Four-colour WUBR": a deck's colours as 17Lands' deck colour table names them. */
    fun colorsName(m: String, s: String): String {
        val base = when (m.length) { 0, 1, 2 -> pairNames[m] ?: m; 3 -> shards[m] ?: "Three-colour"; 4 -> "Four-colour"; else -> "Five-colour" }
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
@Serializable data class ShareRow(val a: Int, val share: Double, val prev: Double? = null, val decks: Int, val top8: Int, val conv: Double? = null)
@Serializable data class CardRow(val c: String, val n: String, val rate: Double, val prev: Double? = null, val copies: Double? = null)
@Serializable data class Movers(val up: List<CardRow>, val down: List<CardRow>)
@Serializable data class Window(val decks: Int, val weighted: Double, val events: Int, val thin: Boolean, val brief: String? = null,
                                val share: List<ShareRow>, val cards: Map<String, Movers>)
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
@Serializable data class Matchups(val archetypes: List<Int>, val cells: List<List<Int>>) {
    /** [a] against [b]: wins, losses, draws from a's side. */
    fun cell(a: Int, b: Int): Triple<Int, Int, Int>? {
        cells.firstOrNull { it[0] == a && it[1] == b }?.let { return Triple(it[2], it[3], it[4]) }
        cells.firstOrNull { it[0] == b && it[1] == a }?.let { return Triple(it[3], it[2], it[4]) }
        return null
    }
}
@Serializable data class EventRow(val name: String, val on: String, val players: Int? = null, val tier: String, val source: String, val url: String? = null,
                                  val top8: List<Int>? = null, val winner: Int? = null)
@Serializable data class ConstructedPack(val format: String, val name: String, val through: String, val sources: List<String>, val default_tier: String,
                                         val archetypes: List<Archetype>, val changes: List<Change>, val events: List<EventRow>,
                                         val tiers: Map<String, View>, val bans: List<BanStudy>, val matchups: Matchups) {
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
    /** Other (archetype 0) only: its decks by colours, each with its most-played cards and its example in [finishes]. */
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
/** One exact colour combination: main colours (WUBRG order, as 17Lands writes them) and the splash ("" for none). */
@Serializable data class LColors(val m: String, val s: String, val games: Int, val wr: Double, val share: Double)
@Serializable data class LView(val games: Int, val wr: Double, val weeks: Int, val brief: String? = null, val pairs: List<LPair>, val cards: List<LCard>, val facts: LFacts,
                               val colors: List<LColors> = emptyList())
@Serializable data class LEvent(val updated: String, val groups: Map<String, LView>)
@Serializable data class Credit(val name: String, val url: String)
@Serializable data class LimitedPack(val set_code: String, val name: String? = null, val released: String? = null, val credit: Credit, val events: Map<String, LEvent>)
