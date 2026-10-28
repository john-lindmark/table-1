package site.table1.events.library

import java.io.ByteArrayInputStream
import java.io.IOException
import java.text.Normalizer
import java.util.zip.GZIPInputStream

// The offline card catalog pack, format 1 (contract/catalog-2026-10-14.md). Plain JVM code with no Android
// or Supabase dependencies, so the unit tests run it directly.

/**
 * Same steps as public.card_name_norm: NFKD, lowercase, drop combining marks, æ → ae, œ → oe, drop
 * apostrophes, every other run outside [a-z0-9] becomes one space, trimmed. For the scanner's printed names
 * (N lines) it also keeps Cyrillic, and Han, kana and Hangul with no space between them (Korean word spaces,
 * "、" and "・" in a name read differently or not at all), recomposed so kana keep their dakuten and Hangul its
 * syllables. English names have none of these, so their name_norm is unchanged.
 */
object CardName {
    /** Furigana written into a Japanese name in brackets ("耕（こう）作（さく）"): the card prints it above the name. */
    private val FURIGANA = Regex("[（(][\u3041-\u309F\u30A0-\u30FF]+[）)]")

    fun norm(s: String): String {
        val plain = if ('（' in s || '(' in s) s.replace(FURIGANA, "") else s
        val d = Normalizer.normalize(plain, Normalizer.Form.NFKD).lowercase()
        val out = StringBuilder(d.length)
        var gap = false
        var lastCjk = false
        var anyCjk = false
        fun emit(c: Int, cjk: Boolean = false) {
            if (gap && out.isNotEmpty() && !(cjk && lastCjk)) out.append(' ')
            gap = false
            lastCjk = cjk
            anyCjk = anyCjk || cjk
            out.appendCodePoint(c)
        }
        var i = 0
        while (i < d.length) {
            val c = d.codePointAt(i)
            i += Character.charCount(c)
            when {
                c in 0x300..0x36F || c == '\''.code || c == '’'.code -> {} // removed outright, not a gap
                c == 'æ'.code -> { emit('a'.code); emit('e'.code) }
                c == 'œ'.code -> { emit('o'.code); emit('e'.code) }
                c in 'a'.code..'z'.code || c in '0'.code..'9'.code || c in 'а'.code..'я'.code -> emit(c) // Cyrillic too: printed names (N lines) are read in Russian
                isCjk(c) -> emit(c, cjk = true)
                else -> gap = true
            }
        }
        return if (anyCjk) Normalizer.normalize(out, Normalizer.Form.NFC) else out.toString()
    }

    /** Han, kana (with the combining dakuten NFKD splits off, and the long-vowel mark, not the middle dot "・") and Hangul. */
    fun isCjk(c: Int): Boolean =
        c in 0x1100..0x11FF || c in 0x3005..0x3007 || c in 0x3041..0x3096 || c in 0x3099..0x309A || c in 0x309D..0x309F ||
            c in 0x30A1..0x30FA || c in 0x30FC..0x30FF || c in 0x3400..0x4DBF || c in 0x4E00..0x9FFF || c in 0xAC00..0xD7A3 ||
            c in 0xF900..0xFAFF || c in 0x20000..0x3134F

    /** True when the text has Han, kana or Hangul in it. */
    fun hasCjk(s: CharSequence): Boolean = s.codePoints().anyMatch(::isCjk)
}

data class PackHeader(val version: String, val oracles: Int, val printings: Int)

data class PackOracle(
    val idx: Int, val oracleId: String, val name: String, val nameNorm: String, val typeLine: String,
    val manaCost: String, val cmc: Double, val colors: String, val faceNames: String,
    /** One character per format in [CatalogPack.LEGALITY_FORMATS]: L legal, R restricted, B banned, - not legal. */
    val legal: String = "",
    /** Canadian Highlander points (0 = none). */
    val points: Int = 0,
    /** Mana the card makes, letters from WUBRGCF; null when the pack doesn't say (older packs, cards not yet read). */
    val produced: String? = null,
    /** O-line indexes of the tokens it makes, comma-separated. */
    val tokens: String = "",
    /** Who it shares the command zone with ([CommandZone.Mate]); null when the pack doesn't say. */
    val pair: String? = null,
    /** Color identity, WUBRG letters (empty = colorless); null when the pack doesn't say. */
    val identity: String? = null,
)

data class PackPrinting(
    val cardId: String, val oracleIdx: Int, val set: String, val cn: String, val lang: String, val rarity: String,
    val finishes: String, val releasedAt: String, val imageTs: String, val imageFaces: Int, val printedName: String,
    /** The card's original paper printing, the one adds use by default. */
    val original: Boolean = false,
)

/** A printed name in another language (N line): what the card is called on its de/es/fr/it/pt/ru printings. */
data class PackName(val oracleIdx: Int, val lang: String, val name: String)

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
     * Streams the (already gunzipped) pack: [oracle] for each O line, [printing] for each P line, [name] for each
     * N line, in file order. Unknown line types and extra trailing fields are ignored; a different format is refused.
     */
    fun parse(text: String, oracle: (PackOracle) -> Unit, printing: (PackPrinting) -> Unit, name: (PackName) -> Unit = {}): PackHeader {
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
                        at(11).toIntOrNull() ?: 0, if (f.size > 12) f[12] else null, at(13), if (f.size > 14) f[14] else null,
                        if (f.size > 15) f[15] else null))
                    o++
                } else if (f[0] == "P" && p < h.printings) {
                    printing(PackPrinting(at(1), at(2).toIntOrNull() ?: -1, at(3), at(4), at(5), at(6), at(7), at(8), at(9),
                        at(10).toIntOrNull() ?: 0, at(11), at(12) == "1"))
                    p++
                } else if (f[0] == "N") {
                    val i = at(1).toIntOrNull()
                    if (i != null && i >= 0 && i < h.oracles && at(3).isNotEmpty()) name(PackName(i, at(2), at(3)))
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
