package site.table1.events.insights

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import site.table1.events.library.CardArtCrop
import site.table1.events.library.CatalogPrinting
import site.table1.events.library.CatalogStore
import site.table1.events.library.IconGlyph
import site.table1.events.library.SelectorRows
import site.table1.events.library.Sheet
import site.table1.events.library.T1Icon
import site.table1.events.ui.components.Label
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.text.Normalizer

/**
 * The Limited page's cards, the grid's Overall column, mana symbols and pasted event codes
 * (contract/insights-2026-10-24.md § The Limited page / § Matchups "Overall"; contract/qr-sign-up-2026-10-23.md § Enter or
 * paste a code). Shared cases: testdata/insights/limited-home.json, overall.json, testdata/mana-symbols/cases.json,
 * testdata/join-code/cases.json.
 */
object LimitedCards {
    /** Cards shown before Show all; hits from other sets once the picked set has none; the shortest query searched. */
    const val TOP = 10
    const val OTHERS_MAX = 20
    const val MIN_QUERY = 2

    /** (value, label, cell code) in each picker's order. */
    val sorts = listOf(Triple("gih", "Win rate in hand", "GIH WR"), Triple("oh", "Win rate in opening hand", "OH WR"),
        Triple("iwd", "Improvement when drawn", "IWD"), Triple("ata", "Average pick taken", "ATA"))
    val rarities = listOf("all" to "Any rarity", "common" to "Common", "uncommon" to "Uncommon", "rare" to "Rare", "mythic" to "Mythic")
    val colors = listOf(Triple("all", "Any color", "Any color"), Triple("W", "White", "W"), Triple("U", "Blue", "U"), Triple("B", "Black", "B"),
        Triple("R", "Red", "R"), Triple("G", "Green", "G"), Triple("M", "Multicolor", "Multi"), Triple("C", "Colorless", "C"))

    /** The pickers' "Any" option: clears the picks (Rarity and Color take several). */
    const val ANY = "all"
    private val rarityOrder = listOf("common", "uncommon", "rare", "mythic")
    private const val COLOR_ORDER = "WUBRGMC"

    /** A multi-pick after a tap: Any clears, another option goes in or out. */
    fun toggle(picked: List<String>, v: String): List<String> =
        if (v == ANY) emptyList() else if (v in picked) picked - v else picked + v

    /** Color picks keep a colorless card when C is picked, a one-color card when its color is, and a multicolor card
     *  when Multi is picked or every one of its colors is (W + U keeps white, blue and Azorius gold cards). */
    fun keepsColor(col: String?, color: List<String>): Boolean {
        if (color.isEmpty()) return true
        val c = col?.takeIf { it.isNotEmpty() } ?: "C"
        return when {
            c == "C" -> "C" in color
            c.length == 1 -> c in color
            else -> "M" in color || c.all { it.toString() in color }
        }
    }

    /** The Rarity cell: Any rarity, the one picked, or the picks' first letters in rarity order (C · U). */
    fun rarityLabel(rarity: List<String>): String {
        val picked = rarityOrder.filter { it in rarity }
        return when (picked.size) {
            0 -> "Any rarity"
            1 -> picked[0].replaceFirstChar { it.uppercase() }
            else -> picked.joinToString(" · ") { it.take(1).uppercase() }
        }
    }

    /** The Color cell: Any color, Multi or Colorless alone, else the colors in WUBRG order then Multi and C (WU · Multi). */
    fun colorLabel(color: List<String>): String {
        val picked = COLOR_ORDER.map { it.toString() }.filter { it in color }
        if (picked.isEmpty()) return "Any color"
        val letters = picked.filter { it in "WUBRG" }.joinToString("")
        val rest = picked.filter { it == "M" || it == "C" }.map { if (it == "M") "Multi" else "C" }
        if (letters.isEmpty() && rest.size == 1) return if (rest[0] == "Multi") "Multi" else "Colorless"
        return (listOfNotNull(letters.takeIf { it.isNotEmpty() }) + rest).joinToString(" · ")
    }

    /** The cards the filters keep, best first: the sort's value high to low (ATA low to high), cards without one last;
     *  ties by games in hand, then name. Rarity and color are picks of several, empty = any. A cube's cards have no
     *  rarity, so the rarity filter is ignored there. The Limited cards widget shows the same list. */
    fun cards(cards: List<LCard>, sort: String, rarity: List<String>, color: List<String>): List<LCard> {
        val rated = cards.any { it.r != null }
        val kept = cards.filter { c -> (!rated || rarity.isEmpty() || c.r in rarity) && keepsColor(c.col, color) }
        fun key(c: LCard): Double? = when (sort) { "oh" -> c.oh; "iwd" -> c.iwd; "ata" -> c.ata?.let { -it }; else -> c.gih }
        return kept.sortedWith { a, b ->
            val x = key(a); val y = key(b)
            when {
                x != null && y != null && x != y -> y.compareTo(x)
                x != null && y == null -> -1
                x == null && y != null -> 1
                a.gih_n != b.gih_n -> b.gih_n.compareTo(a.gih_n)
                else -> a.n.compareTo(b.n)
            }
        }
    }

    /** A row's number for the sort, and for the win rates how far it sits from the view's average, in points. */
    fun value(c: LCard, sort: String, average: Double): Pair<String, String?> = when (sort) {
        "ata" -> (c.ata?.let { "%.1f".format(java.util.Locale.US, it) } ?: "–") to null
        "iwd" -> (c.iwd?.let { InsightCharts.delta(it) } ?: "–") to null
        else -> {
            val x = if (sort == "oh") c.oh else c.gih
            InsightCharts.pct1(x) to x?.let { InsightCharts.delta(it - average) }
        }
    }

    /** Lower case, accents and apostrophes gone, everything else but letters and digits a single space. */
    fun norm(s: String): String =
        Normalizer.normalize(s.lowercase().replace("æ", "ae"), Normalizer.Form.NFKD).replace(Regex("\\p{Mn}+"), "")
            .replace(Regex("['’]"), "").replace(Regex("[^a-z0-9]+"), " ").trim()

    private fun rank(name: String, q: String): Int? {
        val n = norm(name)
        return when { n.startsWith(q) -> 0; " $n".contains(" $q") -> 1; n.contains(q) -> 2; else -> null }
    }

    /** The picked set's cards whose name holds the query (all of them, whatever the filters), starts first; when none
     *  does, the other sets' (up to [OTHERS_MAX]) as (set, name). */
    fun search(query: String, here: List<String>, others: List<Pair<String, List<String>>>): Pair<List<String>, List<Pair<String, String>>> {
        val q = norm(query)
        if (q.length < MIN_QUERY) return emptyList<String>() to emptyList()
        val hits = here.mapNotNull { n -> rank(n, q)?.let { it to n } }.sortedWith(compareBy({ it.first }, { it.second }))
        if (hits.isNotEmpty()) return hits.map { it.second } to emptyList()
        data class More(val r: Int, val n: String, val i: Int, val k: String)
        val more = others.flatMapIndexed { i, (k, names) -> names.mapNotNull { n -> rank(n, q)?.let { More(it, n, i, k) } } }
            .sortedWith(compareBy<More>({ it.r }, { it.n }, { it.i }))
        return emptyList<String>() to more.take(OTHERS_MAX).map { it.k to it.n }
    }

    /** A grid row's overall match record (wins, losses, draws, from the Meta now record): the window's record for the
     *  archetype when it has one, else the sum of its squares against every other row. */
    data class Overall(val wins: Int, val losses: Int, val draws: Int, val fromMeta: Boolean)
    fun overall(share: List<ShareRow>, m: Matchups, a: Int): Overall? {
        share.firstOrNull { it.a == a }?.rec?.takeIf { it.size == 3 && it[0] + it[1] > 0 }?.let { return Overall(it[0], it[1], it[2], true) }
        var w = 0; var l = 0; var d = 0
        for (b in m.rowIds) if (b != a) m.cell(a, b)?.let { (x, y, z) -> w += x; l += y; d += z }
        return if (w + l > 0) Overall(w, l, d, false) else null
    }
}

/** Scryfall's mana symbols, bundled as res/drawable/mana_<name> (tools/mana/make.py). */
object ManaSymbols {
    /** "{2}{W}{U/B}" → ["2", "W", "UB"]; a second face's cost after " // " comes after "//". */
    fun parse(cost: String): List<String> = cost.split(" // ").flatMapIndexed { i, face ->
        (if (i > 0) listOf("//") else emptyList()) + Regex("\\{([^}]+)\\}").findAll(face).map { it.groupValues[1].replace("/", "").uppercase() }
    }
    val names: Set<String> get() = ManaSymbolsData.drawables.keys
}

/** A mana cost as Scryfall's symbols; one the app doesn't bundle is a grey circle with its text. */
@Composable
fun ManaCost(cost: String, size: Dp = 13.dp) {
    val symbols = ManaSymbols.parse(cost)
    if (symbols.isEmpty()) return
    Row(Modifier.semantics { contentDescription = symbols.joinToString(" ") }, horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically) {
        symbols.forEach { s ->
            val res = ManaSymbolsData.drawables[s]
            when {
                s == "//" -> Text("//", color = T1.muted, fontFamily = T1.mono, fontSize = (size.value * 0.8f).sp)
                res != null -> Image(painterResource(res), contentDescription = null, modifier = Modifier.size(size))
                else -> Box(Modifier.size(size).background(Color(0xFFCAC5C0), CircleShape), contentAlignment = Alignment.Center) {
                    Text(s, color = T1.ink, fontFamily = T1.mono, fontSize = (size.value * 0.5f).sp, maxLines = 1)
                }
            }
        }
    }
}

/** A filter as an attribute cell: its value, and the picker it opens (design guidance § Attribute row, § Picker).
 *  Options are (value, label, detail). */
/** `picked`: a filter that takes several picks (Rarity, Color), empty = the "all" option. Its picker stays open, each tap
 *  puts an option in or out, and "all" clears the picks and closes it. */
class FilterCell(val name: String, val value: String, val options: List<Triple<String, String, String?>>, val current: String?,
                 val picked: List<String>? = null, val onPick: (String) -> Unit) {
    companion object {
        /** The option at the end of the format and set pickers that opens Edit. */
        const val EDIT = "__edit"
    }
}

/** Insights' filters: one row of equal cells, 50 dp tall and 1 dp apart, each a dropdown that opens its picker.
 *  [event]: what a changed pick is counted as (Find events counts its own, `find_filtered`). */
@Composable
fun FilterRow(cells: List<FilterCell>, event: String = "insights_filter_changed") {
    // By name, so a multi-pick picker shows the picks as they change.
    var openName by remember { mutableStateOf<String?>(null) }
    val open = cells.firstOrNull { it.name == openName }
    // Four cells (Find events) on a narrow phone: tighter type, so "Any format" and "Everywhere" stay whole.
    val tight = cells.size >= 4
    Row(Modifier.fillMaxWidth().background(T1.bg), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        cells.forEach { c ->
            Row(Modifier.weight(1f).height(50.dp).background(T1.surface).clickable(onClickLabel = c.name) { openName = c.name }
                .semantics { contentDescription = "${c.name}: ${c.value}" }.padding(horizontal = if (tight) 3.dp else 6.dp),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Text(c.value.uppercase(), Modifier.weight(1f, fill = false), color = T1.text, fontFamily = T1.mono, fontSize = if (tight) 10.sp else 11.sp,
                    letterSpacing = if (tight) 0.5.sp else 1.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                IconGlyph(T1Icon.ArrowDropDown, Modifier.size(if (tight) 14.dp else 16.dp), color = T1.muted)
            }
        }
    }
    open?.let { c ->
        Sheet({ openName = null }) {
            val many = c.picked
            if (many != null) {
                SelectorRows(c.options, null, title = c.name, selected = if (many.isEmpty()) setOf(LimitedCards.ANY) else many.toSet(),
                    onDone = { openName = null }) { v ->
                    if (v == LimitedCards.ANY) openName = null
                    Telemetry.capture(event, mapOf("filter" to c.name.lowercase(), "value" to v, "on" to (v == LimitedCards.ANY || v !in many)))
                    c.onPick(v)
                }
            } else {
                SelectorRows(c.options, c.current, title = c.name) { v ->
                    openName = null
                    if (v != c.current && v != FilterCell.EDIT) Telemetry.capture(event, mapOf("filter" to c.name.lowercase(), "value" to v))
                    c.onPick(v)
                }
            }
        }
    }
}

/** A card's mana cost and its printing in the set (for the art); a cube's cards take their original printing. */
data class LimitedFace(val cost: String, val printing: CatalogPrinting?) {
    companion object {
        suspend fun load(set: String, cards: List<LCard>): Map<String, LimitedFace> = withContext(Dispatchers.IO) {
            val db = CatalogStore.db ?: return@withContext emptyMap()
            val oracles = db.oraclesById(cards.mapNotNull { it.c })
            val inSet = HashMap<Int, CatalogPrinting>()
            for (p in db.printings(set.lowercase())) {
                val had = inSet[p.oracleIdx]
                if (had == null || (p.lang == "en" && had.lang != "en")) inSet[p.oracleIdx] = p
            }
            val missing = oracles.values.map { it.idx }.filter { it !in inSet }
            val covers = if (missing.isEmpty()) emptyMap() else db.covers(missing)
            cards.mapNotNull { c ->
                val o = c.c?.let { oracles[it.lowercase()] } ?: return@mapNotNull null
                c.n to LimitedFace(o.manaCost, inSet[o.idx] ?: covers[o.idx])
            }.toMap()
        }
    }
}

/** One card on the Limited page: its place, art, name, mana cost, rarity and games, and the sort's number with how far
 *  it sits from the average under it. */
@Composable
fun LimitedCardRow(rank: Int?, card: LCard, face: LimitedFace?, value: String, vs: String?, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().background(T1.surface).clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        if (rank != null) Text("$rank", Modifier.width(22.dp), color = T1.muted, fontFamily = T1.mono, fontSize = 11.sp, textAlign = TextAlign.End)
        if (face?.printing != null) CardArtCrop(face.printing, Modifier.width(52.dp).height(38.dp))
        else Box(Modifier.width(52.dp).height(38.dp).background(T1.bg))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(card.n, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                face?.cost?.takeIf { it.isNotEmpty() }?.let { ManaCost(it, 12.dp) }
                Label(listOfNotNull(card.r?.take(1)?.uppercase(), "%,d in hand".format(card.gih_n)).joinToString(" · "))
            }
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(value, color = if (card.gih == null) T1.disabled else T1.text, fontFamily = T1.mono, fontSize = 14.sp)
            vs?.let { Label(it, color = if (it.startsWith("+")) T1.text else T1.muted) }
        }
    }
}

/** A screen's one big action with a line of data under it (Rank this set): the words large, the data small. */
@Composable
fun RankAction(title: String, detail: String?, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().heightIn(min = 88.dp).background(T1.surface).border(width = 0.dp, color = Color.Transparent)
        .clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically)) {
        Text(title.uppercase(), color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 4.sp)
        detail?.let { Label(it) }
    }
}

/** An event code read out of pasted text: a table-1.site link wins (/j/<code>?s=… the QR's join, /join/<code>), then the
 *  whole text without spaces and dashes, then a word after "code", then a word of capitals and digits with a digit. */
sealed class JoinCode {
    abstract val code: String
    data class Code(override val code: String) : JoinCode()
    data class Qr(override val code: String, val secret: String) : JoinCode()

    companion object {
        private const val ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        private val isCode = Regex("^[A-Za-z0-9]{4}$")

        fun parse(text: String?): JoinCode? {
            if (text == null) return null
            Regex("(?:https?://)?(?:www\\.)?table-1\\.site(/[^\\s<>\"']*)", RegexOption.IGNORE_CASE).find(text)?.let { m ->
                val uri = runCatching { java.net.URI("https://table-1.site" + m.groupValues[1]) }.getOrNull() ?: return null
                val parts = (uri.rawPath ?: "").split("/").filter { it.isNotEmpty() }
                if (parts.size >= 2 && parts[0] == "j" && isCode.matches(parts[1])) {
                    val s = (uri.rawQuery ?: "").split("&").firstOrNull { it.startsWith("s=") }?.removePrefix("s=")
                        ?.let { java.net.URLDecoder.decode(it, "UTF-8") }
                    if (!s.isNullOrEmpty()) return Qr(parts[1].uppercase(), s)
                }
                if (parts.size >= 2 && parts[0] == "join" && isCode.matches(parts[1])) return Code(parts[1].uppercase())
                return null
            }
            val plain = text.replace(Regex("https?://\\S+"), " ")   // another site's link says nothing about the code
            val bare = plain.replace(Regex("[\\s-]"), "")
            if (isCode.matches(bare)) return Code(bare.uppercase())
            Regex("\\bcode\\b\\W{0,3}(?:is\\W{1,3})?([A-Za-z0-9]{4})\\b", RegexOption.IGNORE_CASE).find(plain)?.let { return Code(it.groupValues[1].uppercase()) }
            return plain.split(Regex("[^A-Za-z0-9]+")).firstOrNull { w -> w.length == 4 && w.all { it in ALPHABET } && w.any { it.isDigit() } }?.let { Code(it) }
        }
    }
}
