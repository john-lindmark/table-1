package site.table1.events.library

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import site.table1.events.T1App
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/* Advanced search (contract/library-polish-2026-10-19.md § Advanced search): Scryfall's query syntax in every Add
   cards search. A plain name is the usual name search. A query with syntax runs on the local card data when every
   key it uses is one the pack carries (name, type, colors, mana value, mana cost, rarity, set, collector number,
   year, language, finish, format legality, mana produced); anything else (card text, power, artist, …) is sent to
   Scryfall's search API and the hits are matched back to the local data by printing id. Same rules as iOS
   `CardQuery.swift`; cases shared with iOS and web: testdata/card-query/cases.json. */

object CardQuery {
    data class Term(
        /** Lowercased key; "" for a bare word (the card's name). */
        val key: String,
        /** ":", "=", "!=", "<", ">", "<=", ">=". */
        val op: String,
        val value: String,
        /** `!"Name"`: the whole name, not a part of it. */
        val exact: Boolean = false,
    )

    sealed interface Node {
        data class And(val parts: List<Node>) : Node
        data class Or(val parts: List<Node>) : Node
        data class Not(val inner: Node) : Node
        data class T(val term: Term) : Node
    }

    private sealed interface Token {
        data object Open : Token
        data object Close : Token
        data object OrT : Token
        data object Neg : Token
        data class Word(val term: Term) : Token
    }

    // ── parsing

    /** True when the query uses any syntax (a key, an operator, a quote, a minus, parentheses or "or"); a plain name
     *  goes to the ranked name search instead. */
    fun hasSyntax(q: String): Boolean {
        val tokens = tokenize(q) ?: return true
        return tokens.any { t -> if (t is Token.Word) t.term.key.isNotEmpty() || t.term.exact || ' ' in t.term.value else true }
    }

    fun parse(q: String): Node? {
        val tokens = tokenize(q) ?: return null
        if (tokens.isEmpty()) return null
        var i = 0
        lateinit var orExpr: () -> Node?
        fun unary(): Node? {
            if (i >= tokens.size) return null
            return when (val t = tokens[i]) {
                Token.Neg -> { i++; unary()?.let { Node.Not(it) } }
                Token.Open -> {
                    i++
                    val inner = orExpr() ?: return null
                    if (i >= tokens.size || tokens[i] != Token.Close) return null
                    i++
                    inner
                }
                is Token.Word -> { i++; Node.T(t.term) }
                Token.Close, Token.OrT -> null
            }
        }
        fun andExpr(): Node? {
            val parts = mutableListOf<Node>()
            while (i < tokens.size && tokens[i] != Token.OrT && tokens[i] != Token.Close) parts.add(unary() ?: return null)
            return when (parts.size) { 0 -> null; 1 -> parts[0]; else -> Node.And(parts) }
        }
        orExpr = {
            val first = andExpr()
            if (first == null) null else {
                val parts = mutableListOf(first)
                var ok = true
                while (ok && i < tokens.size && tokens[i] == Token.OrT) {
                    i++
                    val next = andExpr()
                    if (next == null) ok = false else parts.add(next)
                }
                if (!ok) null else if (parts.size == 1) parts[0] else Node.Or(parts)
            }
        }
        val node = orExpr() ?: return null
        return if (i == tokens.size) node else null
    }

    private val OPS = listOf("!=", "<=", ">=", ":", "=", "<", ">")

    private fun tokenize(q: String): List<Token>? {
        val chars = q.codePoints().toArray().map { String(Character.toChars(it)) }
        val out = mutableListOf<Token>()
        var i = 0
        fun space(s: String) = s.isBlank()
        fun readValue(): String? {
            if (i < chars.size && (chars[i] == "\"" || chars[i] == "'")) {
                val quote = chars[i]
                i++
                val v = StringBuilder()
                while (i < chars.size && chars[i] != quote) v.append(chars[i++])
                if (i >= chars.size) return null
                i++
                return v.toString()
            }
            val v = StringBuilder()
            while (i < chars.size && !space(chars[i]) && chars[i] != "(" && chars[i] != ")") v.append(chars[i++])
            return v.toString()
        }
        while (i < chars.size) {
            val c = chars[i]
            if (space(c)) { i++; continue }
            if (c == "(") { out.add(Token.Open); i++; continue }
            if (c == ")") { out.add(Token.Close); i++; continue }
            if (c == "-" && i + 1 < chars.size && !space(chars[i + 1])) { out.add(Token.Neg); i++; continue }
            if (c == "!") {
                i++
                val v = readValue()
                if (v.isNullOrEmpty()) return null
                out.add(Token.Word(Term("", ":", v, exact = true)))
                continue
            }
            if (c == "\"" || c == "'") {
                val v = readValue() ?: return null
                if (v.isNotEmpty()) out.add(Token.Word(Term("", ":", v)))
                continue
            }
            // A key is letters followed by an operator; otherwise the word is part of the name.
            var j = i
            while (j < chars.size && Character.isLetter(chars[j].codePointAt(0))) j++
            val op = if (j > i) OPS.firstOrNull { o -> j + o.length <= chars.size && chars.subList(j, j + o.length).joinToString("") == o } else null
            if (op != null) {
                val key = chars.subList(i, j).joinToString("").lowercase()
                // Not a key Scryfall knows ("Circle of Protection: Red"): part of the name.
                if (key !in KNOWN_KEYS) {
                    val word = readValue()
                    if (!word.isNullOrEmpty()) out.add(Token.Word(Term("", ":", word)))
                    continue
                }
                i = j + op.length
                val v = readValue() ?: return null
                out.add(Token.Word(Term(key, op, v)))
                continue
            }
            val word = readValue()
            if (word.isNullOrEmpty()) { i++; continue }
            when (word.lowercase()) {
                "or" -> out.add(Token.OrT)
                "and" -> {} // the default between terms
                else -> out.add(Token.Word(Term("", ":", word)))
            }
        }
        return out
    }

    // ── what runs locally

    private val NAME_KEYS = setOf("", "name", "n")
    private val TYPE_KEYS = setOf("t", "type")
    private val COLOR_KEYS = setOf("c", "color", "colors")
    private val MV_KEYS = setOf("mv", "cmc", "manavalue")
    private val MANA_KEYS = setOf("m", "mana")
    private val RARITY_KEYS = setOf("r", "rarity")
    private val SET_KEYS = setOf("s", "set", "e", "edition")
    private val CN_KEYS = setOf("cn", "number")
    private val LANG_KEYS = setOf("lang", "language")
    private val LEGAL_KEYS = setOf("f", "format", "legal")
    private val PRINTING_KEYS = RARITY_KEYS + SET_KEYS + CN_KEYS + LANG_KEYS + setOf("year", "date", "is")
    private val FORMATS = (CatalogPack.LEGALITY_FORMATS + "canlander").toSet()

    /** Every key Scryfall's syntax has (local or not); any other "word:" is part of a card name. */
    private val KNOWN_KEYS: Set<String> = (NAME_KEYS - "") + TYPE_KEYS + COLOR_KEYS + MV_KEYS + MANA_KEYS + PRINTING_KEYS + LEGAL_KEYS +
        setOf("banned", "restricted", "produces", "o", "oracle", "fo", "fulloracle", "pow", "power", "tou", "toughness", "pt", "powtou",
            "loy", "loyalty", "def", "defense", "id", "identity", "ci", "commander", "kw", "keyword", "a", "artist", "ft", "flavor", "wm",
            "watermark", "border", "frame", "game", "in", "st", "art", "atag", "otag", "function", "devotion", "usd", "eur", "tix", "prints",
            "sets", "papersets", "cube", "block", "b", "new", "not", "has", "include", "layout", "stamp", "unique", "order", "prefer",
            "direction", "lore", "hand", "life", "paper")

    private fun num(v: String): Double? = if (Regex("^[+-]?(\\d+\\.?\\d*|\\.\\d+)$").matches(v)) v.toDouble() else null
    private fun int(v: String): Int? = if (Regex("^[+-]?\\d+$").matches(v)) v.toIntOrNull() else null

    /** Whether the local data can answer this term. */
    fun isLocal(t: Term): Boolean {
        val k = t.key
        val v = t.value.lowercase()
        return when {
            k in NAME_KEYS || k in TYPE_KEYS || k in SET_KEYS || k in LANG_KEYS -> v.isNotEmpty()
            k in COLOR_KEYS -> colorSet(v) != null || int(v) != null
            k in MV_KEYS -> num(v) != null || v == "even" || v == "odd"
            k in MANA_KEYS -> manaSymbols(v).isNotEmpty()
            k in RARITY_KEYS -> rarityRank(v) != null
            k in CN_KEYS -> v.isNotEmpty()
            k == "year" -> int(v) != null
            k == "date" -> v.codePointCount(0, v.length) == 10
            k == "is" -> v in setOf("foil", "nonfoil", "etched")
            k in LEGAL_KEYS || k == "banned" || k == "restricted" -> v in FORMATS
            k == "produces" -> colorSet(v) != null
            else -> false
        }
    }

    fun isLocal(n: Node): Boolean = when (n) {
        is Node.And -> n.parts.all(::isLocal)
        is Node.Or -> n.parts.all(::isLocal)
        is Node.Not -> isLocal(n.inner)
        is Node.T -> isLocal(n.term)
    }

    /** Whether any term is about a printing (set, rarity, year, …): those match card by card's printings. */
    fun usesPrinting(n: Node): Boolean = when (n) {
        is Node.And -> n.parts.any(::usesPrinting)
        is Node.Or -> n.parts.any(::usesPrinting)
        is Node.Not -> usesPrinting(n.inner)
        is Node.T -> n.term.key in PRINTING_KEYS
    }

    /** The name words the query asks for (not negated), for ranking. */
    fun nameWords(n: Node): List<String> = when (n) {
        is Node.And -> n.parts.flatMap(::nameWords)
        is Node.Or -> n.parts.flatMap(::nameWords)
        is Node.Not -> emptyList()
        is Node.T -> if (n.term.key in NAME_KEYS) listOf(n.term.value) else emptyList()
    }

    // ── matching

    fun matches(n: Node, o: CatalogOracle, p: CatalogPrinting?): Boolean = when (n) {
        is Node.And -> n.parts.all { matches(it, o, p) }
        is Node.Or -> n.parts.any { matches(it, o, p) }
        is Node.Not -> !matches(n.inner, o, p)
        is Node.T -> matches(n.term, o, p)
    }

    fun matches(t: Term, o: CatalogOracle, p: CatalogPrinting?): Boolean {
        val k = t.key
        val v = t.value.lowercase()
        if (k in NAME_KEYS) {
            val name = CardName.norm(o.name)
            val q = CardName.norm(t.value)
            return if (t.exact) name == q || o.name.lowercase().split(" // ").contains(v) else name.contains(q)
        }
        if (k in TYPE_KEYS) return CardName.norm(o.typeLine).contains(CardName.norm(t.value))
        if (k in COLOR_KEYS || k == "produces") {
            val have = if (k == "produces") (o.produced ?: "").uppercase().filter { it in "WUBRGC" }.toSet()
                else o.colors.uppercase().filter { it in "WUBRG" }.toSet()
            val n = int(v)
            if (n != null && k != "produces") return compare(have.size.toDouble(), t.op, n.toDouble())
            return when (val want = colorSet(v) ?: return false) {
                ColorWant.Colorless -> if (t.op == "!=") have.isNotEmpty() else have.isEmpty()
                ColorWant.Multicolor -> if (t.op == "!=") have.size < 2 else have.size >= 2
                is ColorWant.Colors -> {
                    val w = want.set
                    when (t.op) {
                        "=" -> have == w
                        "!=" -> have != w
                        "<=" -> w.containsAll(have)
                        "<" -> w.containsAll(have) && have.size < w.size
                        ">" -> have.containsAll(w) && have.size > w.size
                        else -> have.containsAll(w) // ":" and ">=": at least these
                    }
                }
            }
        }
        if (k in MV_KEYS) {
            if (v == "even") return o.cmc.toInt() % 2 == 0
            if (v == "odd") return o.cmc.toInt() % 2 == 1
            return num(v)?.let { compare(o.cmc, t.op, it) } ?: false
        }
        if (k in MANA_KEYS) {
            val w = manaSymbols(v).groupingBy { it }.eachCount()
            val h = manaSymbols(o.manaCost.lowercase()).groupingBy { it }.eachCount()
            if (t.op == "=") return w == h
            if (t.op == "!=") return w != h
            return w.all { (s, n) -> (h[s] ?: 0) >= n }
        }
        if (k in LEGAL_KEYS) return o.legality(v) in setOf("legal", "restricted")
        if (k == "banned") return o.legality(v) == "banned"
        if (k == "restricted") return o.legality(v) == "restricted"
        if (p == null) return false
        if (k in RARITY_KEYS) {
            val have = rarityRank(p.rarity) ?: return false
            val want = rarityRank(v) ?: return false
            return compare(have.toDouble(), t.op, want.toDouble())
        }
        if (k in SET_KEYS) return if (t.op == "!=") p.set.lowercase() != v else p.set.lowercase() == v
        if (k in CN_KEYS) {
            if (t.op in setOf("<", ">", "<=", ">=")) {
                val a = int(p.cn.filter { it.isDigit() })
                val b = int(v)
                if (a != null && b != null) return compare(a.toDouble(), t.op, b.toDouble())
            }
            return if (t.op == "!=") p.cn.lowercase() != v else p.cn.lowercase() == v
        }
        if (k in LANG_KEYS) return if (t.op == "!=") p.lang != v else p.lang == v
        if (k == "year") return int(p.releasedAt.take(4))?.let { compare(it.toDouble(), t.op, num(v) ?: 0.0) } ?: false
        if (k == "date") {
            val d = p.releasedAt.take(10)
            return when (t.op) {
                "<" -> d < v
                ">" -> d > v
                "<=" -> d <= v
                ">=" -> d >= v
                "!=" -> d != v
                else -> d == v
            }
        }
        if (k == "is") return p.finishList.any { it.wire == v }
        return false
    }

    private fun compare(a: Double, op: String, b: Double): Boolean = when (op) {
        "<" -> a < b
        ">" -> a > b
        "<=" -> a <= b
        ">=" -> a >= b
        "!=" -> a != b
        else -> a == b
    }

    sealed interface ColorWant {
        data class Colors(val set: Set<Char>) : ColorWant
        data object Colorless : ColorWant
        data object Multicolor : ColorWant
    }

    private val COLOR_NAMES = mapOf(
        "white" to "W", "blue" to "U", "black" to "B", "red" to "R", "green" to "G",
        "azorius" to "WU", "dimir" to "UB", "rakdos" to "BR", "gruul" to "RG", "selesnya" to "GW",
        "orzhov" to "WB", "izzet" to "UR", "golgari" to "BG", "boros" to "RW", "simic" to "GU",
        "bant" to "GWU", "esper" to "WUB", "grixis" to "UBR", "jund" to "BRG", "naya" to "RGW",
        "abzan" to "WBG", "jeskai" to "URW", "sultai" to "BGU", "mardu" to "RWB", "temur" to "GUR",
    )

    fun colorSet(value: String): ColorWant? {
        val v = value.lowercase()
        if (v == "c" || v == "colorless") return ColorWant.Colorless
        if (v == "m" || v == "multicolor") return ColorWant.Multicolor
        COLOR_NAMES[v]?.let { return ColorWant.Colors(it.toSet()) }
        val letters = v.uppercase()
        if (letters.isEmpty() || !letters.all { it in "WUBRG" }) return null
        return ColorWant.Colors(letters.toSet())
    }

    /** Mana symbols as lowercased strings without braces: "{2}{R}{R}" and "2rr" both read as ["2", "r", "r"]. */
    fun manaSymbols(value: String): List<String> {
        val out = mutableListOf<String>()
        val chars = value.lowercase()
        var i = 0
        while (i < chars.length) {
            val c = chars[i]
            when {
                c == '{' -> {
                    val s = StringBuilder()
                    i++
                    while (i < chars.length && chars[i] != '}') s.append(chars[i++])
                    i++
                    if (s.isNotEmpty()) out.add(s.toString())
                }
                c.isDigit() -> {
                    val s = StringBuilder()
                    while (i < chars.length && chars[i].isDigit()) s.append(chars[i++])
                    out.add(s.toString())
                }
                c in "wubrgcxs" -> { out.add(c.toString()); i++ }
                else -> return emptyList()
            }
        }
        return out
    }

    private fun rarityRank(v: String): Int? = when (v.lowercase()) {
        "c", "common" -> 0
        "u", "uncommon" -> 1
        "r", "rare" -> 2
        "m", "mythic" -> 3
        "s", "special" -> 4
        "b", "bonus" -> 5
        else -> null
    }
}

/** Runs a search for an Add cards screen: the ranked name search, the local advanced search, or Scryfall. */
object CardSearchEngine {
    data class Result(
        val hits: List<CatalogOracle> = emptyList(),
        /** The printing each hit shows (and adds): the one a set/rarity/year term matched, else the card's cover. */
        val covers: Map<Int, CatalogPrinting> = emptyMap(),
        val total: Int = 0,
        val remote: Boolean = false,
        val error: String? = null,
    )

    const val LIMIT = 200

    /** Delay before running, in ms: typing settles faster for local searches than for a request to Scryfall. */
    fun debounce(q: String): Long {
        if (!CardQuery.hasSyntax(q)) return 120
        return if (CardQuery.parse(q)?.let(CardQuery::isLocal) == true) 150 else 450
    }

    fun run(q: String, db: CatalogDb): Result {
        val trimmed = q.trim()
        if (!CardQuery.hasSyntax(trimmed)) {
            val hits = db.search(trimmed)
            return Result(hits, db.covers(hits.map { it.idx }), hits.size)
        }
        val node = CardQuery.parse(trimmed)
        if (node != null && CardQuery.isLocal(node)) return local(node, db)
        return scryfall(trimmed, node, db)
    }

    fun local(node: CardQuery.Node, db: CatalogDb): Result {
        val oracles = db.allOracles()
        val found = mutableListOf<CatalogOracle>()
        var covers: Map<Int, CatalogPrinting> = emptyMap()
        if (CardQuery.usesPrinting(node)) {
            val byIdx = oracles.associateBy { it.idx }
            val best = HashMap<Int, CatalogPrinting>()
            // Prefer English with an image, then the original printing, then newest (pack order).
            fun score(x: CatalogPrinting) = (if (x.lang == "en" && x.imageFaces > 0) 2 else 0) + (if (x.original) 1 else 0)
            for (p in db.allPrintings()) {
                val o = byIdx[p.oracleIdx] ?: continue
                if (!CardQuery.matches(node, o, p)) continue
                val b = best[o.idx]
                if (b == null) { best[o.idx] = p; found.add(o) } else if (score(p) > score(b)) best[o.idx] = p
            }
            covers = best
        } else {
            oracles.filterTo(found) { CardQuery.matches(node, it, null) }
        }
        val words = CardQuery.nameWords(node).joinToString(" ")
        var ordered = found.sortedBy { it.name }
        if (CardName.norm(words).length >= 2) {
            val ranked = CatalogPack.rank(found.map { CatalogPack.SearchCandidate(it.idx, it.norm, it.typeLine, it.printings) }, words, found.size)
            val byIdx = found.associateBy { it.idx }
            val inRank = ranked.toSet()
            ordered = ranked.mapNotNull { byIdx[it] } + ordered.filter { it.idx !in inRank }
        }
        val shown = ordered.take(LIMIT)
        if (covers.isEmpty()) covers = db.covers(shown.map { it.idx })
        return Result(shown, covers, found.size)
    }

    @Serializable
    private data class Page(
        @SerialName("total_cards") val totalCards: Int? = null,
        val data: List<Card>? = null,
        val details: String? = null,
    ) {
        @Serializable
        data class Card(val id: String, @SerialName("oracle_id") val oracleId: String? = null)
    }

    /** Scryfall's /cards/search (one card per Oracle card, by name), matched to the local data by printing id. */
    fun scryfall(q: String, node: CardQuery.Node?, db: CatalogDb): Result {
        val url = URL("https://api.scryfall.com/cards/search?q=${URLEncoder.encode(q, "UTF-8")}&unique=cards&order=name")
        val conn = url.openConnection() as HttpURLConnection
        return try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 15_000
            conn.setRequestProperty("User-Agent", "Table1Events/1.0 (table-1.site)")
            conn.setRequestProperty("Accept", "application/json")
            val status = conn.responseCode
            if (status == 404) return Result(remote = true)
            val body = (if (status == 200) conn.inputStream else conn.errorStream)?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
            val page = runCatching { T1App.json.decodeFromString(Page.serializer(), body) }.getOrNull() ?: Page()
            if (status != 200) return Result(remote = true, error = page.details ?: "Scryfall couldn't read that search ($status)")
            val cards = page.data ?: emptyList()
            val printings = db.printings(cards.map { it.id.lowercase() })
            val idxs = mutableListOf<Int>()
            val shownPrinting = HashMap<Int, CatalogPrinting>()
            for (c in cards) {
                val p = printings[c.id.lowercase()]
                if (p != null) {
                    if (shownPrinting[p.oracleIdx] == null) { idxs.add(p.oracleIdx); shownPrinting[p.oracleIdx] = p }
                } else {
                    val o = c.oracleId?.let { db.oracle(it.lowercase()) }
                    if (o != null && o.idx !in idxs) idxs.add(o.idx)
                }
            }
            val oracles = db.oracles(idxs)
            val hits = idxs.mapNotNull { oracles[it] }.take(LIMIT)
            // Scryfall's printing only when the query names one (a set, a year, …); otherwise the usual cover.
            val covers = db.covers(hits.map { it.idx }).toMutableMap()
            if (node == null || CardQuery.usesPrinting(node)) for ((k, p) in shownPrinting) if (k in covers) covers[k] = p
            Result(hits, covers, page.totalCards ?: hits.size, remote = true)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result(remote = true, error = "Searching card text needs a connection to Scryfall.")
        } finally {
            conn.disconnect()
        }
    }
}

/** The Advanced search form's fields; `query` writes them as Scryfall syntax into the search box. */
data class AdvancedSearchFields(
    val name: String = "",
    val text: String = "",
    val type: String = "",
    /** WUBRG, or C for colorless. */
    val colors: Set<Char> = emptySet(),
    val colorMode: ColorMode = ColorMode.Including,
    val mvOp: String = "=",
    val mv: String = "",
    /** c u r m */
    val rarities: Set<Char> = emptySet(),
    val set: String = "",
    val format: String = "",
) {
    enum class ColorMode(val wire: String, val label: String) {
        Exactly("exactly", "Exactly"), Including("including", "Including"), AtMost("atMost", "At most");
        companion object { fun of(wire: String) = entries.firstOrNull { it.wire == wire } ?: Including }
    }

    val query: String get() {
        fun quoted(s: String): String {
            val t = s.trim().replace("\"", "")
            return if (' ' in t) "\"$t\"" else t
        }
        val parts = mutableListOf<String>()
        name.trim().takeIf { it.isNotEmpty() }?.let { parts.add(it) }
        if (text.isNotBlank()) parts.add("o:${quoted(text)}")
        for (word in type.split(" ")) if (word.isNotEmpty()) parts.add("t:${word.lowercase()}")
        if ('C' in colors) {
            parts.add("c:c")
        } else if (colors.isNotEmpty()) {
            val letters = "WUBRG".filter { it in colors }.lowercase()
            parts.add("c${when (colorMode) { ColorMode.Exactly -> "="; ColorMode.AtMost -> "<="; ColorMode.Including -> ">=" }}$letters")
        }
        mv.replace(",", ".").let { s -> if (Regex("^[+-]?(\\d+\\.?\\d*|\\.\\d+)$").matches(s)) s.toDouble() else null }?.let { v ->
            val n = if (v == Math.rint(v)) v.toLong().toString() else v.toString()
            parts.add("mv$mvOp$n")
        }
        val r = "curm".filter { it in rarities }.map { "r:$it" }
        if (r.size == 1) parts.add(r[0]) else if (r.size > 1) parts.add("(${r.joinToString(" or ")})")
        set.trim().lowercase().takeIf { it.isNotEmpty() }?.let { parts.add("s:$it") }
        if (format.isNotEmpty()) parts.add("f:$format")
        return parts.joinToString(" ")
    }
}
