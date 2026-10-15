package site.table1.events.library

import java.io.ByteArrayInputStream
import java.io.IOException
import java.text.Normalizer
import java.util.zip.GZIPInputStream

// The offline card catalog pack, format 1 (contract/catalog-2026-10-14.md). Plain JVM code with no Android
// or Supabase dependencies, so the unit tests run it directly.

/**
 * Same steps as public.card_name_norm: NFKD, lowercase, drop combining marks, æ → ae, œ → oe, drop
 * apostrophes, every other run outside [a-z0-9] becomes one space, trimmed.
 */
object CardName {
    fun norm(s: String): String {
        val d = Normalizer.normalize(s, Normalizer.Form.NFKD).lowercase()
        val out = StringBuilder(d.length)
        var gap = false
        fun emit(c: Char) {
            if (gap && out.isNotEmpty()) out.append(' ')
            gap = false
            out.append(c)
        }
        for (c in d) when {
            c in '̀'..'ͯ' || c == '\'' || c == '’' -> {} // removed outright, not a gap
            c == 'æ' -> { emit('a'); emit('e') }
            c == 'œ' -> { emit('o'); emit('e') }
            c in 'a'..'z' || c in '0'..'9' -> emit(c)
            else -> gap = true
        }
        return out.toString()
    }
}

data class PackHeader(val version: String, val oracles: Int, val printings: Int)

data class PackOracle(
    val idx: Int, val oracleId: String, val name: String, val nameNorm: String, val typeLine: String,
    val manaCost: String, val cmc: Double, val colors: String, val faceNames: String,
    /** One character per format in [CatalogPack.LEGALITY_FORMATS]: L legal, R restricted, B banned, - not legal. */
    val legal: String = "",
    /** Canadian Highlander points (0 = none). */
    val points: Int = 0,
)

data class PackPrinting(
    val cardId: String, val oracleIdx: Int, val set: String, val cn: String, val lang: String, val rarity: String,
    val finishes: String, val releasedAt: String, val imageTs: String, val imageFaces: Int, val printedName: String,
    /** The card's original paper printing, the one adds use by default. */
    val original: Boolean = false,
)

class CatalogFormatException(message: String) : IOException(message)

object CatalogPack {
    /** Formats in an O line's legality code, in order. */
    val LEGALITY_FORMATS = listOf("standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander", "premodern")

    /** A legality code read for one format: legal, restricted, banned, not_legal, or null when the format isn't covered. */
    fun legality(code: String, format: String): String? {
        // Canadian Highlander follows Vintage, and restricted cards are legal there (every card is a singleton).
        val f = format.lowercase()
        val i = LEGALITY_FORMATS.indexOf(if (f == "canlander") "vintage" else f)
        if (i < 0 || i >= code.length) return null
        return when (code[i]) { 'L' -> "legal"; 'R' -> if (f == "canlander") "legal" else "restricted"; 'B' -> "banned"; else -> "not_legal" }
    }

    /** Canadian Highlander: at most this many points per deck (canadianhighlander.ca/points-list). */
    const val CANLANDER_POINT_LIMIT = 10

    /** A deck format as players write it. */
    fun formatName(format: String) = if (format == "canlander") "Canadian Highlander" else format.replaceFirstChar { it.uppercase() }

    val FINISH_NAME = mapOf('n' to "nonfoil", 'f' to "foil", 'e' to "etched")
    val RARITY_NAME = mapOf("c" to "Common", "u" to "Uncommon", "r" to "Rare", "m" to "Mythic", "s" to "Special", "b" to "Bonus")

    /**
     * Streams the (already gunzipped) pack: [oracle] for each O line, [printing] for each P line, in file
     * order. Unknown line types and extra trailing fields are ignored; a different format is refused.
     */
    fun parse(text: String, oracle: (PackOracle) -> Unit, printing: (PackPrinting) -> Unit): PackHeader {
        var header: PackHeader? = null
        var o = 0
        var p = 0
        var start = 0
        val n = text.length
        while (start < n) {
            var end = text.indexOf('\n', start)
            if (end < 0) end = n
            if (end > start) {
                val f = text.substring(start, end).split('\t')
                fun at(i: Int) = f.getOrElse(i) { "" }
                val h = header
                if (h == null) {
                    if (at(0) != "#t1catalog" || at(1) != "1") throw CatalogFormatException("Unknown card data format")
                    header = PackHeader(at(2), at(3).toIntOrNull() ?: 0, at(4).toIntOrNull() ?: 0)
                } else if (f[0] == "O" && o < h.oracles) {
                    oracle(PackOracle(at(1).toIntOrNull() ?: o, at(2), at(3), at(4), at(5), at(6), at(7).toDoubleOrNull() ?: 0.0, at(8), at(9), at(10),
                        at(11).toIntOrNull() ?: 0))
                    o++
                } else if (f[0] == "P" && p < h.printings) {
                    printing(PackPrinting(at(1), at(2).toIntOrNull() ?: -1, at(3), at(4), at(5), at(6), at(7), at(8), at(9),
                        at(10).toIntOrNull() ?: 0, at(11), at(12) == "1"))
                    p++
                }
                // Unknown line types are skipped (format rule).
            }
            start = end + 1
        }
        return header ?: throw CatalogFormatException("Unknown card data format")
    }

    /** The pack is a gzip object (not HTTP Content-Encoding), so it's inflated here. */
    fun gunzip(bytes: ByteArray): ByteArray =
        try {
            GZIPInputStream(ByteArrayInputStream(bytes), 1 shl 16).use { it.readBytes() }
        } catch (e: IOException) {
            throw CatalogFormatException("Card data is damaged")
        }

    /** Scryfall CDN image for one printing; images never go through our servers. */
    fun imageUrl(cardId: String, imageTs: String, size: String = "normal", back: Boolean = false): String? {
        if (cardId.length < 2) return null
        val ts = if (imageTs.isEmpty()) "" else "?$imageTs"
        return "https://cards.scryfall.io/$size/${if (back) "back" else "front"}/${cardId[0]}/${cardId[1]}/$cardId.jpg$ts"
    }

    data class SearchCandidate(val idx: Int, val norm: String, val type: String, val printings: Int)

    private val EXTRA = Regex("^(Token|Card|Emblem)\\b|\\bToken\\b")

    /**
     * Name search ranking, same as the web client: exact name, then a word starting with the query, then any
     * substring, then tokens and art cards; within a tier the most-reprinted card first, then shorter names.
     * [candidates] may be any superset of the cards whose name contains the query.
     */
    fun rank(candidates: List<SearchCandidate>, query: String, limit: Int = 30): List<Int> {
        val q = CardName.norm(query)
        if (q.length < 2) return emptyList()
        val word = " $q"
        val tiers = List(4) { mutableListOf<SearchCandidate>() }
        for (c in candidates) {
            var t = when {
                c.norm == q -> 0
                c.norm.startsWith(q) || c.norm.contains(word) -> 1
                c.norm.contains(q) -> 2
                else -> continue
            }
            if (t > 0 && EXTRA.containsMatchIn(c.type)) t = 3
            tiers[t].add(c)
        }
        val order = compareByDescending<SearchCandidate> { it.printings }.thenBy { it.norm.length }.thenBy { it.norm }
        return tiers.flatMap { it.sortedWith(order) }.take(limit).map { it.idx }
    }
}
