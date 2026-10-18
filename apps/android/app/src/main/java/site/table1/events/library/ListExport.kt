package site.table1.events.library

// Deck and cube export (contract/lists-2026-10-15.md, Export): the current version as Arena, Moxfield, MTGO or plain
// text, or as a Cube Cobra CSV. Same rules and output as iOS (ListExport.swift) and web (listExport.ts):
// testdata/list-export holds the files all three must write for its lists, and list-import's parser reads each one
// back as the same lines (supabase/functions/list-import/parse.test.ts).
//  - Names: double-faced, adventure and flip cards by their front face, split cards (and rooms) by both halves, the
//    way Arena, Moxfield and Cube Cobra name them.
//  - Printings are "(SET) number". A set code or collector number the importers can't read is left off (the line
//    then imports as that card's original printing).
//  - Lines sort by name, then set, collector number and finish.

/** What exporting and importing lists read from the catalog (CatalogDb on a phone, the test pack in unit tests). */
interface ListCatalog {
    fun printings(ids: Collection<String>): Map<String, CatalogPrinting>
    fun oracles(idxs: Collection<Int>): Map<Int, CatalogOracle>
    /** Default printings for names as decklists print them, front faces included. */
    fun printingsByName(names: Collection<String>): Map<String, CatalogPrinting>
    /** "set|cn" → printing, English first. */
    fun printingsBySetCn(pairs: Collection<Pair<String, String>>): Map<String, CatalogPrinting>
}

object ListExport {
    enum class Format(val wire: String, val label: String, val detail: String, val fileExtension: String?) {
        Arena("arena", "MTG Arena", "Deck, sideboard and commander with printings, to paste into Import", null),
        Moxfield("moxfield", "Moxfield", "Printings, foils and considering, to paste into Import", null),
        Mtgo("mtgo", "MTGO", "A .txt file: the main deck, then the sideboard", "txt"),
        Text("text", "Plain text", "Counts and card names", null),
        CubeCobra("cubecobra", "Cube Cobra", "A CSV for Replace with CSV file upload", "csv");

        companion object {
            fun formats(kind: ListKind) = if (kind == ListKind.Deck) listOf(Arena, Moxfield, Mtgo, Text) else listOf(CubeCobra, Text)
        }
    }

    data class Card(val name: String, val typeLine: String, val cmc: Double, val colors: String, val set: String, val cn: String, val rarity: String)
    data class Line(val card: Card, val board: String, val qty: Int, val finish: String = "nonfoil")

    /** The list's lines with their cards from the catalog; `left` counts copies the catalog doesn't have. */
    fun lines(entries: List<ListEntry>, db: ListCatalog): Pair<List<Line>, Int> {
        val printings = db.printings(entries.map { it.cardId })
        val oracles = db.oracles(printings.values.map { it.oracleIdx }.toSet())
        val out = ArrayList<Line>()
        var left = 0
        for (e in entries) {
            val p = printings[e.cardId]
            val o = p?.let { oracles[it.oracleIdx] }
            if (p == null || o == null) { left += e.qty; continue }
            out += Line(Card(o.name, o.typeLine, o.cmc, o.colors, p.set, p.cn, p.rarity), e.board, e.qty, e.finish)
        }
        return out to left
    }

    /** The name other apps know the card by. */
    fun name(c: Card): String {
        val faces = c.name.split(" // ")
        if (faces.size < 2) return c.name
        val split = c.typeLine.split(" // ").all { t ->
            "Adventure" !in t && "Omen" !in t &&
                (t == "Instant" || t == "Sorcery" || t.startsWith("Instant — ") || t.startsWith("Sorcery — ") || t == "Enchantment — Room")
        }
        return if (split) c.name else faces[0]
    }

    private val SET = Regex("[A-Za-z0-9]{2,6}")
    private val CN = Regex("[A-Za-z0-9★†Φ_\\-]+")

    /** "(SET) number", or null when the importers couldn't read it back. */
    fun printing(c: Card): String? =
        if (SET.matches(c.set) && CN.matches(c.cn)) "(${c.set.uppercase()}) ${c.cn}" else null

    private val FINISH_RANK = mapOf("nonfoil" to 0, "foil" to 1, "etched" to 2)
    /** UTF-16 order, as iOS and web sort. */
    private val ORDER = compareBy<Line>({ name(it.card) }, { it.card.set }, { it.card.cn }, { FINISH_RANK[it.finish] ?: 3 })

    /** Sums lines that print the same, keeping the first one's place. */
    private fun merged(lines: List<Line>, text: (Line) -> String): List<String> {
        val qty = LinkedHashMap<String, Int>()
        for (l in lines) text(l).let { qty[it] = (qty[it] ?: 0) + l.qty }
        return qty.map { (t, q) -> "$q $t" }
    }

    fun render(lines: List<Line>, kind: ListKind, format: Format): String {
        val sorted = lines.filter { it.qty > 0 }.sortedWith(ORDER)
        if (format == Format.CubeCobra) return cubeCobra(sorted)
        fun board(vararg b: String) = sorted.filter { it.board in b }
        fun printed(l: Line) = listOfNotNull(name(l.card), printing(l.card)).joinToString(" ")
        val blocks = ArrayList<List<String>>()
        when (format) {
            Format.Arena, Format.Moxfield -> {
                val sections = mutableListOf("Commander" to board("commander"), "Deck" to board("main"), "Sideboard" to board("side"))
                if (format == Format.Moxfield) sections += "Maybeboard" to board("maybe")
                for ((title, ls) in sections) {
                    if (ls.isEmpty()) continue
                    val rows = if (format == Format.Arena) merged(ls, ::printed)
                    else merged(ls) { printed(it) + when (it.finish) { "foil" -> " *F*"; "etched" -> " *E*"; else -> "" } }
                    blocks += listOf(title) + rows
                }
            }
            // MTGO has no commander section: the commander goes in the sideboard, as MTGO's Commander decks do.
            Format.Mtgo -> listOf(merged(board("main")) { name(it.card) }, merged(board("side", "commander")) { name(it.card) })
                .filter { it.isNotEmpty() }.forEach { blocks += it }
            else -> {
                val sections = if (kind == ListKind.Deck)
                    listOf("Commander" to board("commander"), "Deck" to board("main"), "Sideboard" to board("side"), "Considering" to board("maybe"))
                else listOf("Main" to board("main", "side", "commander"), "Considering" to board("maybe"))
                val filled = sections.filter { it.second.isNotEmpty() }
                for ((title, ls) in filled) {
                    val rows = merged(ls) { name(it.card) }
                    blocks += if (filled.size > 1) listOf(title) + rows else rows
                }
            }
        }
        return if (blocks.isEmpty()) "" else blocks.joinToString("\n\n") { it.joinToString("\n") } + "\n"
    }

    /**
     * Cube Cobra's own CSV columns and quoting (its export, which its bulk upload reads): one row per copy, the main
     * list then Considering (maybeboard). Color Category, status, images, notes and tags are left for Cube Cobra.
     */
    const val CUBE_COBRA_HEADER =
        "name,CMC,Type,Color,Set,Collector Number,Rarity,Color Category,status,Finish,board,maybeboard,image URL,image Back URL,tags,Notes,MTGO ID,Custom,Voucher,Artist"
    private val RARITY = mapOf("c" to "common", "u" to "uncommon", "r" to "rare", "m" to "mythic", "s" to "special", "b" to "bonus")

    private fun cubeCobra(sorted: List<Line>): String {
        fun q(s: String) = "\"" + s.replace("\"", "\"\"") + "\""
        val rows = mutableListOf(CUBE_COBRA_HEADER)
        for (maybe in listOf(false, true)) {
            for (l in sorted) {
                if ((l.board == "maybe") != maybe) continue
                val c = l.card
                val cmc = if (c.cmc == Math.rint(c.cmc)) c.cmc.toLong().toString() else c.cmc.toString()
                val colors = "WUBRG".filter { it in c.colors }
                val finish = when (l.finish) { "foil" -> "Foil"; "etched" -> "Etched"; else -> "Non-foil" }
                // Cube Cobra swaps the first dash back.
                val row = listOf(q(name(c)), cmc, q(c.typeLine.replaceFirst("—", "-")), colors, q(c.set), q(c.cn), RARITY[c.rarity] ?: "", "", "",
                    finish, if (maybe) "maybeboard" else "mainboard", maybe.toString(), "", "", q(""), q(""), "", "false", "false", q(""))
                    .joinToString(",")
                repeat(l.qty) { rows += row }
            }
        }
        return rows.joinToString("\r\n") + "\r\n"
    }

    /** "Izzet Tempo.txt": the list's name with only letters, digits, spaces, dashes and underscores. */
    fun fileName(listName: String, kind: ListKind, format: Format): String {
        val base = listName.filter { it.isLetterOrDigit() || it in " -_" }.split(" ").filter { it.isNotEmpty() }.joinToString(" ").take(60)
        return "${base.ifEmpty { kind.wire }}.${format.fileExtension ?: "txt"}"
    }
}
