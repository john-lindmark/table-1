package site.table1.events.library

// Collection CSV import and export (contract/collection-import-2026-10-17.md). CollectionCSV reads another app's
// export into rows (format detection, columns, each app's words for finish, condition and language) and writes the
// collection in Moxfield's or ManaBox's layout. ImportResolver matches rows to printings in the local catalog.
// Same rules as iOS CollectionCSV.swift and table-1-events-web/src/lib/collectionCsv.ts; the fixtures in
// testdata/collection-import test all three. Plain JVM code, so the unit tests run it directly.

enum class CSVFormat(val wire: String, val label: String) {
    ManaBox("manabox", "ManaBox"), Moxfield("moxfield", "Moxfield"), Archidekt("archidekt", "Archidekt"),
    Deckbox("deckbox", "Deckbox"), DragonShield("dragonshield", "Dragon Shield"), TCGplayer("tcgplayer", "TCGplayer"),
    DelverLens("delverlens", "Delver Lens"), Other("other", "CSV");

    /** ManaBox and Dragon Shield grade on Cardmarket's scale (Excellent, Good, Light played, Played, Poor). */
    val cardmarketScale get() = this == ManaBox || this == DragonShield
}

/** One line of an imported file, its values already mapped to ours. */
data class ImportRow(
    /** 1-based line number in the file. */
    val line: Int,
    val name: String,
    /** Lowercased. */
    val setCode: String? = null,
    val setName: String? = null,
    val cn: String? = null,
    val scryfallId: String? = null,
    val qty: Int = 1,
    val finish: String = "nonfoil",
    val condition: String = "NM",
    val lang: String = "en",
    /** Why the line can't be read at all (it's listed as unmatched). */
    val problem: String? = null,
) {
    val setLabel get() = listOfNotNull(setCode?.uppercase() ?: setName, cn?.let { "#$it" }).joinToString(" ")
}

data class ParsedImport(val format: CSVFormat, val rows: List<ImportRow>)

class CSVFailure(message: String) : Exception(message)

object CollectionCSV {
    // ── reading ──────────────────────────────────────────────────────────

    fun parse(input: String): ParsedImport {
        val text = input.removePrefix("﻿")
        var start = 0
        var line = 1
        var delimiter: Char? = null
        // Dragon Shield and Excel: a first line `sep=,` names the delimiter.
        val firstEnd = text.indexOf('\n').let { if (it < 0) text.length else it }
        val first = text.substring(0, firstEnd).trim { it == '"' || it == '\r' || it == ' ' }.lowercase()
        if (first.startsWith("sep=") && first.length == 5) {
            delimiter = first.last()
            start = minOf(firstEnd + 1, text.length)
            line = 2
        }
        val sepLine = delimiter != null
        val d = delimiter ?: guessDelimiter(text, start)
        val records = records(text, start, d, line)
        val header = records.firstOrNull() ?: throw CSVFailure("This file is empty.")
        val keys = header.fields.map(::headerKey)
        val format = detect(keys.toSet(), sepLine)
        val cols = Columns(keys, format)
        if (cols.name == null && cols.id == null) throw CSVFailure("This file has no card name column.")

        val rows = ArrayList<ImportRow>(records.size)
        for (r in records.drop(1)) {
            fun at(i: Int?): String = if (i == null || i >= r.fields.size) "" else r.fields[i].trim(::isSpace)
            val name = at(cols.name)
            val id = at(cols.id)
            if (name.isEmpty() && id.isEmpty()) continue
            var problem: String? = null
            var qty = 1
            if (cols.qty != null) {
                val q = quantity(at(cols.qty))
                if (q != null) qty = q else problem = "Quantity isn't a number"
            }
            if (qty == 0 && problem == null) continue
            var finish = finish(at(cols.finish))
            var rawCondition = at(cols.condition)
            // TCGplayer seller exports grade foils as "Near Mint Foil"; its app marks etched in the name.
            if (rawCondition.lowercase().endsWith(" foil")) {
                rawCondition = rawCondition.dropLast(5)
                if (finish == "nonfoil") finish = "foil"
            }
            if (format == CSVFormat.TCGplayer && "etched" in at(cols.fullName).lowercase()) finish = "etched"
            var setCode = at(cols.setCode).lowercase()
            if (format == CSVFormat.DragonShield && GUILD_KIT.containsMatchIn(setCode)) setCode = setCode.take(3) // GK2_AZORIU → gk2
            var setName = at(cols.setName)
            if (cols.setEither != null) {
                val v = at(cols.setEither)
                if (setCode.isEmpty()) setCode = v.lowercase()
                if (setName.isEmpty()) setName = v
            }
            val cn = at(cols.cn).substringBefore('/')
            rows.add(ImportRow(
                line = r.line, name = name, setCode = setCode.ifEmpty { null }, setName = setName.ifEmpty { null },
                cn = cn.ifEmpty { null }, scryfallId = id.ifEmpty { null }?.lowercase(), qty = qty, finish = finish,
                condition = condition(rawCondition, format.cardmarketScale), lang = language(at(cols.lang)), problem = problem,
            ))
        }
        return ParsedImport(format, rows)
    }

    private val GUILD_KIT = Regex("^gk[12]_")

    /** Swift's CharacterSet.whitespaces: tabs and space separators, not line ends. */
    private fun isSpace(c: Char) = c == '\t' || Character.getType(c) == Character.SPACE_SEPARATOR.toInt()

    /** Lowercase, letters and digits only: `Collector's number` → `collectorsnumber`. */
    fun headerKey(s: String): String = s.lowercase().filter { it in 'a'..'z' || it in '0'..'9' }

    fun detect(h: Set<String>, sepLine: Boolean = false): CSVFormat = when {
        "quantityx" in h || "delverlocalid" in h -> CSVFormat.DelverLens
        ("foldername" in h && "cardname" in h) || (sepLine && "tradequantity" in h) -> CSVFormat.DragonShield
        "simplename" in h || ("tcgplayerid" in h && "productname" in h) -> CSVFormat.TCGplayer
        "manaboxid" in h || "bindertype" in h || "purchasepricecurrency" in h -> CSVFormat.ManaBox
        ("editioncode" in h && "editionname" in h) || ("dateadded" in h && "finish" in h) -> CSVFormat.Archidekt
        "tradelistcount" in h && "cardnumber" in h -> CSVFormat.Deckbox
        "tradelistcount" in h && "edition" in h -> CSVFormat.Moxfield
        else -> CSVFormat.Other
    }

    /** Which column holds what, by format (contract table "Columns"). */
    private class Columns(private val keys: List<String>, format: CSVFormat) {
        private fun col(vararg names: String): Int? = names.firstNotNullOfOrNull { n -> keys.indexOf(n).takeIf { it >= 0 } }

        val name = if (format == CSVFormat.TCGplayer) col("simplename", "productname", "name") else col("name", "cardname", "card", "simplename", "productname")
        val fullName = col("name", "productname")
        val qty = col("quantity", "count", "qty", "quantityx", "totalquantity", "amount")
        val setCode: Int?
        val setName: Int?
        var setEither: Int? = null
        val cn = col("collectornumber", "cardnumber", "collectorsnumber", "number", "cn", "collectorno")
        val finish = col("foil", "finish", "printing", "foiling")
        val condition = col("condition")
        val lang = col("language", "lang")
        val id = col("scryfallid", "scryfalluuid")

        init {
            when (format) {
                CSVFormat.Moxfield -> { setCode = col("edition", "setcode", "editioncode"); setName = col("setname", "editionname") }
                CSVFormat.Deckbox, CSVFormat.DelverLens -> { setCode = col("editioncode", "setcode"); setName = col("edition", "editionname", "setname") }
                CSVFormat.TCGplayer -> { setCode = col("setcode"); setName = col("set", "setname") }
                else -> {
                    setCode = col("setcode", "editioncode", "code")
                    setName = col("setname", "editionname", "expansion")
                    if (setCode == null || setName == null) setEither = col("set", "edition")
                }
            }
        }
    }

    /** `2x` → 2, blank → 1, not a number → null. */
    fun quantity(v: String): Int? {
        val t = v.trim(::isSpace)
        if (t.isEmpty()) return 1
        val digits = t.filter { it in '0'..'9' }
        if (digits.isEmpty() || !t.lowercase().all { it.isDigit() || it == 'x' || it == ' ' }) return null
        return digits.take(9).toInt()
    }

    private val NONFOIL = setOf("", "normal", "nonfoil", "non-foil", "non foil", "no", "false", "0", "n", "regular")

    fun finish(v: String): String {
        val s = v.trim(::isSpace).lowercase()
        return when {
            "etched" in s -> "etched"
            s in NONFOIL -> "nonfoil"
            "foil" in s || s in setOf("true", "yes", "1", "y") -> "foil"
            else -> "nonfoil"
        }
    }

    private val usConditions = mapOf(
        "m" to "NM", "mint" to "NM", "nm" to "NM", "nearmint" to "NM", "nmm" to "NM",
        "lp" to "LP", "lightlyplayed" to "LP", "goodlightlyplayed" to "LP", "slightlyplayed" to "LP", "sp" to "LP",
        "ex" to "LP", "excellent" to "LP", "good" to "LP", "gd" to "LP", "lightplayed" to "LP",
        "mp" to "MP", "moderatelyplayed" to "MP", "played" to "MP", "pl" to "MP",
        "hp" to "HP", "heavilyplayed" to "HP",
        "d" to "DMG", "dmg" to "DMG", "damaged" to "DMG", "poor" to "DMG", "po" to "DMG",
    )
    private val cardmarketConditions = mapOf(
        "m" to "NM", "mint" to "NM", "nm" to "NM", "nearmint" to "NM",
        "ex" to "LP", "excellent" to "LP", "gd" to "LP", "good" to "LP",
        "lp" to "MP", "lightplayed" to "MP", "lightlyplayed" to "MP",
        "pl" to "HP", "played" to "HP",
        "po" to "DMG", "poor" to "DMG",
    )

    fun condition(v: String, cardmarket: Boolean): String {
        val k = headerKey(v)
        return (if (cardmarket) cardmarketConditions[k] else null) ?: usConditions[k] ?: "NM"
    }

    private val languages = mapOf(
        "en" to "en", "english" to "en", "de" to "de", "german" to "de", "deutsch" to "de", "fr" to "fr", "french" to "fr",
        "it" to "it", "italian" to "it", "es" to "es", "sp" to "es", "spanish" to "es", "pt" to "pt", "ptbr" to "pt", "portuguese" to "pt",
        "portuguesebrazil" to "pt", "ja" to "ja", "jp" to "ja", "japanese" to "ja", "ko" to "ko", "kr" to "ko", "korean" to "ko",
        "ru" to "ru", "russian" to "ru", "zhs" to "zhs", "zhcn" to "zhs", "zhhans" to "zhs", "cs" to "zhs", "chinese" to "zhs",
        "chinesesimplified" to "zhs", "simplifiedchinese" to "zhs", "zht" to "zht", "zhtw" to "zht", "zhhant" to "zht", "ct" to "zht",
        "chinesetraditional" to "zht", "traditionalchinese" to "zht", "he" to "he", "hebrew" to "he", "la" to "la", "latin" to "la",
        "grc" to "grc", "ancientgreek" to "grc", "ar" to "ar", "arabic" to "ar", "sa" to "sa", "sanskrit" to "sa", "ph" to "ph",
        "phyrexian" to "ph", "qya" to "qya", "quenya" to "qya",
    )

    fun language(v: String): String = languages[headerKey(v)] ?: "en"

    /** The delimiter that appears most in the first line, outside quotes (a comma on a tie). */
    fun guessDelimiter(text: String, start: Int = 0): Char {
        val counts = intArrayOf(0, 0, 0)
        val candidates = charArrayOf(',', '\t', ';')
        var quoted = false
        for (i in start until text.length) {
            val c = text[i]
            if (c == '\n' && !quoted) break
            if (c == '"') quoted = !quoted
            else if (!quoted) candidates.indexOf(c).let { if (it >= 0) counts[it]++ }
        }
        var best = 0
        for (i in 1..2) if (counts[i] > counts[best]) best = i
        return candidates[best]
    }

    class Record(val line: Int, val fields: List<String>)

    /** RFC 4180 records (quotes, `""`, newlines in quotes, CRLF or LF), each with its first line number. */
    fun records(text: String, start: Int, delimiter: Char, firstLine: Int = 1): List<Record> {
        val out = ArrayList<Record>()
        var fields = ArrayList<String>()
        val field = StringBuilder()
        var quoted = false
        var wasQuoted = false
        var line = firstLine
        var recordLine = firstLine
        fun endField() {
            var end = field.length
            if (!wasQuoted && end > 0 && field[end - 1] == '\r') end--
            fields.add(field.substring(0, end))
            field.setLength(0)
            wasQuoted = false
        }
        fun endRecord() {
            endField()
            if (!(fields.size == 1 && fields[0].isEmpty())) out.add(Record(recordLine, fields))
            fields = ArrayList()
        }
        var i = start
        val n = text.length
        while (i < n) {
            val c = text[i]
            if (quoted) {
                if (c == '"') {
                    if (i + 1 < n && text[i + 1] == '"') { field.append('"'); i++ } else quoted = false
                } else {
                    if (c == '\n') line++
                    field.append(c)
                }
            } else if (c == '"' && field.isEmpty()) {
                quoted = true
                wasQuoted = true
            } else if (c == delimiter) {
                endField()
            } else if (c == '\n') {
                endRecord()
                line++
                recordLine = line
            } else if (!(c == '\r' && wasQuoted)) {
                field.append(c)
            }
            i++
        }
        if (field.isNotEmpty() || fields.isNotEmpty()) endRecord()
        return out
    }

    // ── writing ──────────────────────────────────────────────────────────

    enum class Layout(val wire: String, val label: String) { Moxfield("moxfield", "Moxfield"), ManaBox("manabox", "ManaBox") }

    data class ExportCard(
        val name: String, val set: String, val setName: String, val cn: String, val rarity: String, val cardId: String,
        val finish: String, val condition: String, val lang: String, val qty: Int,
    )

    private val moxfieldConditions = mapOf("NM" to "Near Mint", "LP" to "Lightly Played", "MP" to "Moderately Played",
        "HP" to "Heavily Played", "DMG" to "Damaged")
    private val manaboxConditions = mapOf("NM" to "near_mint", "LP" to "excellent", "MP" to "light_played", "HP" to "played", "DMG" to "poor")
    private val languageNames = mapOf(
        "en" to "English", "de" to "German", "fr" to "French", "it" to "Italian", "es" to "Spanish", "pt" to "Portuguese",
        "ja" to "Japanese", "ko" to "Korean", "ru" to "Russian", "zhs" to "Chinese Simplified", "zht" to "Chinese Traditional",
        "he" to "Hebrew", "la" to "Latin", "grc" to "Ancient Greek", "ar" to "Arabic", "sa" to "Sanskrit", "ph" to "Phyrexian", "qya" to "Quenya",
    )
    private val rarities = mapOf("c" to "common", "u" to "uncommon", "r" to "rare", "m" to "mythic", "s" to "special", "b" to "bonus")

    /** Sorted by name, set and collector number; CRLF line ends. */
    fun export(cards: List<ExportCard>, layout: Layout): String {
        val sorted = cards.sortedWith(compareBy<ExportCard>({ it.name }, { it.set }, { it.cn.length }, { it.cn },
            { "${it.finish}|${it.condition}|${it.lang}" }))
        val lines = ArrayList<String>(sorted.size + 1)
        when (layout) {
            Layout.Moxfield -> {
                fun q(s: String) = "\"" + s.replace("\"", "\"\"") + "\""
                lines.add(listOf("Count", "Tradelist Count", "Name", "Edition", "Condition", "Language", "Foil", "Tags", "Last Modified",
                    "Collector Number", "Alter", "Proxy", "Purchase Price").joinToString(",", transform = ::q))
                for (c in sorted) {
                    lines.add(listOf(c.qty.toString(), "0", c.name, c.set, moxfieldConditions[c.condition] ?: "Near Mint",
                        languageNames[c.lang] ?: "English", if (c.finish == "nonfoil") "" else c.finish, "", "", c.cn,
                        "False", "False", "").joinToString(",", transform = ::q))
                }
            }
            Layout.ManaBox -> {
                fun q(s: String) = if (s.any { it == ',' || it == '"' || it == '\n' || it == '\r' }) "\"" + s.replace("\"", "\"\"") + "\"" else s
                lines.add("Name,Set code,Set name,Collector number,Foil,Rarity,Quantity,ManaBox ID,Scryfall ID,Purchase price,Misprint,Altered,Condition,Language,Purchase price currency")
                for (c in sorted) {
                    lines.add(listOf(c.name, c.set.uppercase(), c.setName, c.cn, if (c.finish == "nonfoil") "normal" else c.finish,
                        rarities[c.rarity] ?: "common", c.qty.toString(), "", c.cardId, "", "false", "false",
                        manaboxConditions[c.condition] ?: "near_mint", c.lang, "USD").joinToString(",", transform = ::q))
                }
            }
        }
        return lines.joinToString("\r\n") + "\r\n"
    }
}

// ── matching ─────────────────────────────────────────────────────────────

/** What the resolver reads from the catalog: CatalogDb on a phone, the test pack in memory in unit tests. */
interface ImportCatalog {
    fun setCodes(): Set<String>
    /** Every card's normalized name and face names (joined with ` // `). */
    fun importNames(): List<ImportName>
    fun printings(ids: Collection<String>): Map<String, CatalogPrinting>
    /** Every printing in one set. */
    fun printings(set: String): List<CatalogPrinting>
    /** One printing per card: its original paper printing first (CatalogDb.covers). */
    fun covers(oracleIdxs: Collection<Int>): Map<Int, CatalogPrinting>
}

data class ImportName(val idx: Int, val norm: String, val faces: String, val token: Boolean, val printings: Int)

/** How a line found its printing (contract "Matching"). */
enum class MatchHow { Id, SetNumber, SetName, Name, Fixed }

data class ResolvedLine(val row: ImportRow, val printing: CatalogPrinting, val finish: String, val how: MatchHow)

/** One collection item the import writes. */
data class ImportItem(val cardId: String, val finish: String, val condition: String, val lang: String, val qty: Int) {
    val key get() = itemKey(cardId, finish, condition, lang)
}

/**
 * Matches imported rows to printings: Scryfall id, then set + collector number, then set + name, then the name's
 * original printing. Builds its name index once and loads each set's printings once, so a 20k-line file costs one
 * pass. Used from one coroutine at a time.
 */
class ImportResolver(private val db: ImportCatalog, setNames: List<Pair<String, String>>) {
    private class SetPrintings(val byCn: Map<String, List<CatalogPrinting>>, val byOracle: Map<Int, List<CatalogPrinting>>)
    private class Names(val norm: String, val faces: List<String>)

    /** Normalized set name → set code (mtg_sets). */
    private val setByName = HashMap<String, String>()
    private val setCodes = db.setCodes()
    private val byFullName = HashMap<String, Int>()
    private val byFace = HashMap<String, Int>()
    private val names = HashMap<Int, Names>()
    private val sets = HashMap<String, SetPrintings>()
    private val originals = HashMap<Int, CatalogPrinting>()
    private val byId = HashMap<String, CatalogPrinting>()
    private val askedIds = HashSet<String>()
    private val nameCache = HashMap<String, Int?>()

    init {
        for ((code, name) in setNames) setByName.putIfAbsent(CardName.norm(name), code)
        // Two cards with one name: the non-token one with more printings.
        val rank = HashMap<Int, Pair<Boolean, Int>>()
        fun better(a: Int, than: Int?): Boolean {
            val ra = rank[a]
            val rb = than?.let { rank[it] }
            if (ra == null || rb == null) return true
            return if (ra.first != rb.first) !ra.first else ra.second > rb.second
        }
        for (o in db.importNames()) {
            rank[o.idx] = o.token to o.printings
            val faces = if (o.faces.isEmpty()) emptyList() else o.faces.split(" // ").map(CardName::norm)
            names[o.idx] = Names(o.norm, faces)
            if (better(o.idx, byFullName[o.norm])) byFullName[o.norm] = o.idx
            for (f in faces) if (better(o.idx, byFace[f])) byFace[f] = o.idx
        }
    }

    /** Matched lines in file order, and the rows that matched nothing. */
    fun resolve(rows: List<ImportRow>): Pair<List<ResolvedLine>, List<ImportRow>> {
        loadIds(rows.mapNotNull { it.scryfallId })
        loadOriginals(rows.mapNotNullTo(HashSet()) { r -> if (r.scryfallId?.let { byId[it] } == null) oracle(r.name) else null })
        val matched = ArrayList<ResolvedLine>(rows.size)
        val unmatched = ArrayList<ImportRow>()
        for (r in rows) resolve(r)?.let { matched.add(it) } ?: unmatched.add(r)
        return matched to unmatched
    }

    fun resolve(r: ImportRow): ResolvedLine? {
        if (r.problem != null) return null
        r.scryfallId?.let { id ->
            loadIds(listOf(id))
            byId[id]?.let { return line(r, it, MatchHow.Id) }
        }
        val idx = oracle(r.name)
        for (code in setCandidates(r)) {
            val set = printings(code)
            r.cn?.let { cn ->
                for (v in listOf(cn, cn.lowercase(), cn.trimStart('0'))) {
                    if (v.isEmpty()) continue
                    val found = (set.byCn[v] ?: emptyList()).filter { p -> idx == null || r.name.isEmpty() || matches(p.oracleIdx, r.name, idx) }
                    best(found, r.lang)?.let { return line(r, it, MatchHow.SetNumber) }
                }
            }
            if (idx != null) best(set.byOracle[idx] ?: emptyList(), r.lang)?.let { return line(r, it, MatchHow.SetName) }
        }
        if (idx != null) original(idx)?.let { return line(r, it, MatchHow.Name) }
        return null
    }

    /** A line fixed by hand: the picked card's printing in the line's set when it has one, else its original printing. */
    fun resolve(r: ImportRow, oracleIdx: Int): ResolvedLine? {
        val row = r.copy(problem = null)
        for (code in setCandidates(row)) {
            best(printings(code).byOracle[oracleIdx] ?: emptyList(), row.lang)?.let { return line(row, it, MatchHow.Fixed) }
        }
        return original(oracleIdx)?.let { line(row, it, MatchHow.Fixed) }
    }

    companion object {
        /** Lines on the same item summed, in first-seen order. */
        fun items(lines: List<ResolvedLine>): List<ImportItem> {
            val by = LinkedHashMap<String, ImportItem>()
            for (l in lines) {
                val it = ImportItem(l.printing.cardId, l.finish, l.row.condition, l.row.lang, l.row.qty)
                val held = by[it.key]
                by[it.key] = if (held == null) it else held.copy(qty = held.qty + it.qty)
            }
            return by.values.toList()
        }

        private val DECORATION = Regex("\\s*[\\[(][^\\[\\]()]*[\\])]$")
        private val TOKEN = Regex("\\s+(token|emblem)$", RegexOption.IGNORE_CASE)
    }

    // ── lookups ──────────────────────────────────────────────────────────

    private fun loadIds(ids: List<String>) {
        // Filtered one by one: never walk every asked id per line (a 20k-line file made that quadratic on iOS).
        val fresh = ids.filterTo(HashSet()) { it !in askedIds }
        if (fresh.isEmpty()) return
        askedIds.addAll(fresh)
        byId.putAll(db.printings(fresh))
    }

    /** Exact name, then a face, then the name without a trailing `[…]`/`(…)` or ` Token`/` Emblem`. */
    fun oracle(raw: String): Int? {
        if (nameCache.containsKey(raw)) return nameCache[raw]
        val found = lookup(raw)
        nameCache[raw] = found
        return found
    }

    private fun lookup(raw: String): Int? {
        val n = CardName.norm(raw)
        if (n.isEmpty()) return null
        (byFullName[n] ?: byFace[n])?.let { return it }
        var s = raw.trim()
        while (true) {
            val m = DECORATION.find(s) ?: break
            s = s.removeRange(m.range)
        }
        TOKEN.find(s)?.let { s = s.removeRange(it.range) }
        val n2 = CardName.norm(s)
        return if (n2 == n || n2.isEmpty()) null else byFullName[n2] ?: byFace[n2]
    }

    private fun matches(oracleIdx: Int, name: String, nameIdx: Int?): Boolean {
        if (oracleIdx == nameIdx) return true
        val o = names[oracleIdx] ?: return false
        val n = CardName.norm(name)
        return o.norm == n || n in o.faces
    }

    /** The set code if the catalog has it, else the set name's code (Deckbox token sets "Extras: X" → tX first). */
    private fun setCandidates(r: ImportRow): List<String> {
        val out = LinkedHashSet<String>()
        r.setCode?.let { if (it in setCodes) out.add(it) }
        r.setName?.let { name ->
            var n = name
            var extras = false
            if (n.lowercase().startsWith("extras:")) { n = n.drop(7); extras = true }
            val k = CardName.norm(n)
            val code = setByName[k] ?: n.lowercase().takeIf { it in setCodes }
                ?: (if (k.endsWith(" edition")) setByName[k.dropLast(8)] else null)
            if (code != null) {
                if (extras && "t$code" in setCodes) out.add("t$code")
                if (code in setCodes) out.add(code)
            }
        }
        return out.toList()
    }

    private fun printings(code: String): SetPrintings = sets.getOrPut(code) {
        val all = db.printings(code)
        SetPrintings(all.groupBy { it.cn }, all.groupBy { it.oracleIdx })
    }

    private fun loadOriginals(idxs: Set<Int>) {
        val missing = idxs.filter { it !in originals }
        if (missing.isEmpty()) return
        originals.putAll(db.covers(missing))
    }

    private fun original(idx: Int): CatalogPrinting? {
        if (idx !in originals) loadOriginals(setOf(idx))
        return originals[idx]
    }

    /** The copy's language printed, then English, then the original printing, then the lowest collector number. */
    private fun best(ps: List<CatalogPrinting>, lang: String): CatalogPrinting? {
        fun num(p: CatalogPrinting) = p.cn.takeWhile { it in '0'..'9' }.toIntOrNull() ?: Int.MAX_VALUE
        return ps.minWithOrNull(compareBy<CatalogPrinting>({ if (it.lang == lang) 0 else if (it.lang == "en") 1 else 2 },
            { if (it.original) 0 else 1 }, ::num, { it.ord }))
    }

    /** The file's finish when the printing has it; etched falls back to foil, then the printing's first finish. */
    private fun line(r: ImportRow, p: CatalogPrinting, how: MatchHow): ResolvedLine {
        val have = p.finishList.map { it.wire }
        val finish = when {
            r.finish in have -> r.finish
            r.finish == "etched" && "foil" in have -> "foil"
            else -> have.firstOrNull() ?: "nonfoil"
        }
        return ResolvedLine(r, p, finish, how)
    }
}
