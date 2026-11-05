package site.table1.events.library

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

// Sideboard guides (contract/sideboard-guide-2026-11-04.md): per matchup, what comes in (sideboard or Considering),
// what goes out (main deck) and notes; printed for Competitive REL (MTR 2.11). The rules are
// testdata/sideboard-guide/make_cases.py; iOS SideboardGuide.swift and web sideboardGuide.ts match it.

/** [oracle_id, qty] on the wire. */
@Serializable(with = GuideCardSerializer::class)
data class GuideCard(val oracle: String, val qty: Int)

object GuideCardSerializer : KSerializer<GuideCard> {
    override val descriptor: SerialDescriptor = JsonArray.serializer().descriptor
    override fun serialize(encoder: Encoder, value: GuideCard) =
        JsonArray.serializer().serialize(encoder, JsonArray(listOf(JsonPrimitive(value.oracle), JsonPrimitive(value.qty))))
    override fun deserialize(decoder: Decoder): GuideCard =
        JsonArray.serializer().deserialize(decoder).let { GuideCard(it[0].jsonPrimitive.content, it[1].jsonPrimitive.int) }
}

enum class GuideSide { In, Out }

@Serializable
data class Matchup(val id: String, val name: String, val archetype: Int? = null,
                   @SerialName("in") val ins: List<GuideCard> = emptyList(), @SerialName("out") val outs: List<GuideCard> = emptyList(),
                   val notes: String = "") {
    fun qty(oracle: String, side: GuideSide) = (if (side == GuideSide.In) ins else outs).firstOrNull { it.oracle == oracle }?.qty ?: 0

    /** A card's count on one side (0 takes it off), keeping the order cards were added. */
    fun set(oracle: String, qty: Int, side: GuideSide): Matchup {
        val cards = (if (side == GuideSide.In) ins else outs).toMutableList()
        val i = cards.indexOfFirst { it.oracle == oracle }
        if (i >= 0) { if (qty <= 0) cards.removeAt(i) else cards[i] = GuideCard(oracle, min(99, qty)) }
        else if (qty > 0) cards.add(GuideCard(oracle, min(99, qty)))
        return if (side == GuideSide.In) copy(ins = cards) else copy(outs = cards)
    }
}

@Serializable
data class SideboardGuide(val matchups: List<Matchup> = emptyList()) {
    fun matchup(id: String) = matchups.firstOrNull { it.id == id }
}

object SideboardRules {
    const val MAX_MATCHUPS = 40
    const val MAX_NAME = 40
    const val MAX_NOTES = 1000
    const val SIDEBOARD_MAX = 15
    private val CAPPED = setOf("modern", "pioneer", "standard", "legacy", "vintage", "pauper", "canlander")

    /** A deck line by card: what the rules need. */
    data class Line(val oracle: String, val name: String, val board: String, val qty: Int)
    data class Copies(val name: String, var main: Int = 0, var side: Int = 0, var maybe: Int = 0)

    sealed interface Issue {
        data class Gone(val side: GuideSide, val oracle: String) : Issue
        data class InOver(val oracle: String, val have: Int) : Issue
        data class OutOver(val oracle: String, val have: Int) : Issue
        data class Considering(val oracle: String, val qty: Int) : Issue
        data class BelowMin(val deck: Int, val min: Int) : Issue
    }
    data class Check(val ins: Int, val outs: Int, val deck: Int, val label: String, val issues: List<Issue>)

    fun hasGuide(format: String) = format !in CommandZone.FORMATS
    fun deckMin(format: String): Int? = if (format == "canlander") 100 else if (format in CAPPED) 60 else null

    /** Copies per card in the main deck, sideboard and Considering (the command zone isn't the deck here). */
    fun pool(lines: List<Line>): Map<String, Copies> {
        val out = LinkedHashMap<String, Copies>()
        for (l in lines) {
            val c = out.getOrPut(l.oracle) { Copies(l.name) }
            when (l.board) { "main" -> c.main += l.qty; "side" -> c.side += l.qty; "maybe" -> c.maybe += l.qty }
        }
        return out
    }

    fun label(ins: Int, outs: Int) = if (ins == 0 && outs == 0) "NO CHANGES" else "IN $ins · OUT $outs"

    fun check(m: Matchup, lines: List<Line>, format: String): Check {
        val p = pool(lines)
        val mainTotal = lines.filter { it.board == "main" }.sumOf { it.qty }
        val issues = mutableListOf<Issue>()
        var tookIn = 0
        for (c in m.ins) {
            val have = p[c.oracle] ?: Copies("")
            val avail = have.side + have.maybe
            if (avail == 0) { issues += Issue.Gone(GuideSide.In, c.oracle); continue }
            if (c.qty > avail) issues += Issue.InOver(c.oracle, avail)
            val took = min(c.qty, avail)
            tookIn += took
            if (took - have.side > 0) issues += Issue.Considering(c.oracle, took - have.side)
        }
        var tookOut = 0
        for (c in m.outs) {
            val have = p[c.oracle]?.main ?: 0
            if (have == 0) { issues += Issue.Gone(GuideSide.Out, c.oracle); continue }
            if (c.qty > have) issues += Issue.OutOver(c.oracle, have)
            tookOut += min(c.qty, have)
        }
        val after = mainTotal + tookIn - tookOut
        deckMin(format)?.let { if (after < it) issues += Issue.BelowMin(after, it) }
        val ins = m.ins.sumOf { it.qty }
        val outs = m.outs.sumOf { it.qty }
        return Check(ins, outs, after, label(ins, outs), issues)
    }

    fun sideboardCount(lines: List<Line>) = lines.filter { it.board == "side" }.sumOf { it.qty }

    /** The sideboard's size when it's over 15 in a capped format (CR 100.4a), else null. */
    fun overSideboard(lines: List<Line>, format: String): Int? = sideboardCount(lines).takeIf { format in CAPPED && it > SIDEBOARD_MAX }

    /** How many matchups bring each card in. */
    fun uses(g: SideboardGuide): Map<String, Int> {
        val out = HashMap<String, Int>()
        for (m in g.matchups) for (c in m.ins) if (c.qty > 0) out.merge(c.oracle, 1, Int::plus)
        return out
    }

    /** One issue as a sentence for the matchup screen. */
    fun text(i: Issue, names: Map<String, Copies>): String {
        fun name(o: String) = names[o]?.name ?: "A card"
        return when (i) {
            is Issue.Gone -> if (i.side == GuideSide.In) "${name(i.oracle)} isn't in the sideboard or Considering anymore." else "${name(i.oracle)} isn't in the main deck anymore."
            is Issue.InOver -> "Only ${i.have} ${name(i.oracle)} to bring in."
            is Issue.OutOver -> "Only ${i.have} ${name(i.oracle)} in the main deck."
            is Issue.Considering -> "${i.qty} ${name(i.oracle)} from Considering: not printed until it's in the sideboard."
            is Issue.BelowMin -> "The deck goes to ${i.deck} cards, under ${i.min}."
        }
    }

    /** A matchup name as the server keeps it: trimmed, at most 40 characters. */
    fun name(raw: String) = raw.trim().take(MAX_NAME)

    // ── printing ──

    data class PrintMatchup(val name: String, val ins: List<Pair<Int, String>>, val outs: List<Pair<Int, String>>, val notes: String)
    data class PrintModel(val deck: String, val format: String, val date: String, val sideboard: List<Pair<Int, String>>, val matchups: List<PrintMatchup>)
    data class Warning(val code: String, val qty: Int)
    data class Printed(val model: PrintModel, val warnings: List<Warning>, val sheets: Int)

    /** What the printed guide shows: only sideboard copies come in, outs capped at the main deck's copies, cards no
     *  longer in the deck left out. */
    fun printModel(deck: String, formatName: String, date: String, lines: List<Line>, guide: SideboardGuide, format: String): Printed {
        val p = pool(lines)
        var leftConsidering = 0
        var leftGone = 0
        val matchups = guide.matchups.map { m ->
            val ins = mutableListOf<Pair<Int, String>>()
            for (c in m.ins) {
                val have = p[c.oracle]
                if (have == null || have.side + have.maybe == 0) { leftGone += c.qty; continue }
                val took = min(c.qty, have.side)
                leftConsidering += min(c.qty, have.side + have.maybe) - took
                if (took > 0) ins += took to have.name
            }
            val outs = mutableListOf<Pair<Int, String>>()
            for (c in m.outs) {
                val have = p[c.oracle]
                if (have == null || have.main == 0) { leftGone += c.qty; continue }
                outs += min(c.qty, have.main) to have.name
            }
            PrintMatchup(m.name, ins, outs, m.notes)
        }
        val side = p.values.filter { it.side > 0 }.map { it.side to it.name }.sortedBy { it.second.lowercase() }
        val model = PrintModel(deck, formatName, date, side, matchups)
        val warnings = mutableListOf<Warning>()
        if (leftConsidering > 0) warnings += Warning("considering", leftConsidering)
        if (leftGone > 0) warnings += Warning("gone", leftGone)
        overSideboard(lines, format)?.let { warnings += Warning("sideboard_over", it) }
        val s = sheets(model)
        if (s > 2) warnings += Warning("sheets", s)
        return Printed(model, warnings, s)
    }

    private const val LINES_PER_PAGE = 120
    private const val HEADER_LINES = 10
    private const val NOTE_CHARS_PER_LINE = 40

    /** About how many pages the printed guide takes (MTR 2.11 allows a sheet or two). */
    fun sheets(m: PrintModel): Int {
        var total = HEADER_LINES
        for (x in m.matchups) {
            val notes = if (x.notes.isEmpty()) 0 else 1 + x.notes.split("\n").sumOf { max(1, ceil(it.codePointCount(0, it.length) / NOTE_CHARS_PER_LINE.toDouble()).toInt()) }
            total += 4 + maxOf(x.ins.size, x.outs.size, 1) + notes
        }
        total += 4 + max(m.sideboard.size, 1)
        return max(1, ceil(total / LINES_PER_PAGE.toDouble()).toInt())
    }

    fun warningText(w: Warning): String = when (w.code) {
        "considering" -> "${w.qty} ${if (w.qty == 1) "card" else "cards"} from Considering left out: only the sideboard can come in."
        "gone" -> "${w.qty} ${if (w.qty == 1) "card" else "cards"} no longer in the deck left out."
        "sideboard_over" -> "The sideboard has ${w.qty} cards: Constructed allows 15."
        else -> "About ${w.qty} pages: the rules allow a sheet or two."
    }

    private fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#39;")

    private const val CSS = "@page{margin:12mm}" +
        "*{box-sizing:border-box;margin:0;padding:0}" +
        "html{-webkit-print-color-adjust:exact;print-color-adjust:exact}" +
        "body{font-family:ui-monospace,\"SF Mono\",\"JetBrains Mono\",Menlo,Consolas,monospace;color:#171725;" +
        "background:#fff;font-size:9pt;line-height:1.35}" +
        "header{border-bottom:2px solid #00ffd9;padding-bottom:6pt;margin-bottom:8pt}" +
        ".mark,.meta,.rule,.lab,h2{text-transform:uppercase;letter-spacing:.15em}" +
        ".mark{font-size:7pt;color:#545461}" +
        "h1{font-size:16pt;font-weight:600;margin:2pt 0}" +
        ".meta{font-size:7.5pt;color:#545461}" +
        ".rule{font-size:6.5pt;color:#545461;margin-top:2pt}" +
        "main{columns:2;column-gap:8pt}" +
        "section{break-inside:avoid;border:1px solid #c4c4ca;margin-bottom:8pt;padding:6pt}" +
        "h2{font-size:8pt;font-weight:600;padding-bottom:4pt;border-bottom:1px solid #c4c4ca;margin-bottom:4pt}" +
        ".io{display:flex;gap:6pt}" +
        ".col{flex:1;min-width:0}" +
        ".lab{font-size:6.5pt;color:#545461;margin-bottom:2pt}" +
        ".row{display:flex;gap:4pt}" +
        ".q{width:2.4em;flex:none;font-weight:600}" +
        ".none{color:#545461}" +
        ".notes{margin-top:4pt;padding-top:4pt;border-top:1px solid #c4c4ca;font-size:8pt;white-space:pre-wrap}"

    private const val RULE = "MTR 2.11 · Between games only · Remove from the play area before each game"

    private fun rows(cards: List<Pair<Int, String>>, sign: String) =
        if (cards.isEmpty()) "<div class=\"none\">—</div>"
        else cards.joinToString("") { "<div class=\"row\"><span class=\"q\">$sign${it.first}</span><span>${esc(it.second)}</span></div>" }

    /** The printed page (light paper in Table 1's type and grid); must equal testdata/sideboard-guide/guide.html. */
    fun html(m: PrintModel): String = buildString {
        append("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n")
        append("<title>${esc(m.deck)} · Sideboard guide</title>\n")
        append("<style>$CSS</style>\n</head>\n<body>\n<header>\n")
        append("<div class=\"mark\">Table 1</div>\n")
        append("<h1>${esc(m.deck)}</h1>\n")
        append("<div class=\"meta\">${esc(m.format)} · Sideboard guide · ${esc(m.date)}</div>\n")
        append("<div class=\"rule\">$RULE</div>\n</header>\n<main>\n")
        for (x in m.matchups) {
            append("<section>\n<h2>${esc(x.name)}</h2>\n<div class=\"io\">\n")
            append("<div class=\"col\"><div class=\"lab\">In · ${x.ins.sumOf { it.first }}</div>${rows(x.ins, "+")}</div>\n")
            append("<div class=\"col\"><div class=\"lab\">Out · ${x.outs.sumOf { it.first }}</div>${rows(x.outs, "−")}</div>\n</div>\n")
            if (x.notes.isNotEmpty()) append("<p class=\"notes\">${esc(x.notes)}</p>\n")
            append("</section>\n")
        }
        append("<section>\n<h2>Sideboard · ${m.sideboard.sumOf { it.first }}</h2>\n${rows(m.sideboard, "")}\n</section>\n")
        append("</main>\n</body>\n</html>\n")
    }

    /** The deck's lines by card (names and oracle ids). */
    fun lines(rows: List<ListLine>): List<Line> = rows.mapNotNull { l -> l.oracleId?.let { Line(it, l.name, l.board, l.qty) } }
}
