package site.table1.events.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/*
 * Budgets for a 20,000-line ManaBox file, same cases as iOS CollectionImportPerfTests: parsing it, and matching it
 * against the real catalog pack by Scryfall id and by set + collector number. Runs on the JVM (testDebugUnitTest)
 * against the pack held in memory, so the numbers are a regression signal (a lost index, a quadratic loop), not phone
 * timings. On John's Mac (2026-10-17): parse 17-33 ms, match by id 20-34 ms, by set + number 56-66 ms; budgets sit ~3x
 * above that.
 */
private object ImportBudget {
    const val PARSE_MS = 100.0
    const val RESOLVE_MS = 200.0
}

class CollectionImportPerfTest {
    companion object {
        /** 20,000 real printings from the test pack written as a ManaBox export. */
        private val bigFile: String by lazy {
            val pack = String(CatalogPack.gunzip(File(root, "catalog.tsv.gz").readBytes()))
            val names = HashMap<Int, String>()
            val lines = mutableListOf("Binder Name,Binder Type,Name,Set code,Set name,Collector number,Foil,Rarity,Quantity,ManaBox ID,Scryfall ID,Purchase price,Misprint,Altered,Condition,Language,Purchase price currency")
            var n = 0
            for (l in pack.lineSequence()) {
                if (n >= 20_000) break
                val c = l.split('\t')
                if (c[0] == "O") names[c[1].toInt()] = c[3]
                if (c[0] == "P" && c[5] == "en") {
                    val name = names[c[2].toInt()] ?: continue
                    val q = if (',' in name || '"' in name) "\"" + name.replace("\"", "\"\"") + "\"" else name
                    lines.add("Binder,binder,$q,${c[3].uppercase()},Some Set,${c[4]},${if ('f' in c[7] && n % 5 == 0) "foil" else "normal"},common,${n % 4 + 1},$n,${c[1]},0.10,false,false,near_mint,en,USD")
                    n++
                }
            }
            lines.joinToString("\n")
        }
    }

    private fun ms(t0: Long) = (System.nanoTime() - t0) / 1e6

    @Test
    fun parseAndResolve20kLines() {
        val text = bigFile
        val db = TestImportCatalog.db
        repeat(2) { CollectionCSV.parse(text) } // JIT warm-up
        val t0 = System.nanoTime()
        val parsed = CollectionCSV.parse(text)
        val parseMs = ms(t0)
        assertEquals(20_000, parsed.rows.size)
        val t1 = System.nanoTime()
        val (matched, _) = ImportResolver(db, TestImportCatalog.setNames).resolve(parsed.rows)
        val resolveMs = ms(t1)
        println("perf android import parse 20k lines: ${parseMs.toInt()} ms (budget ${ImportBudget.PARSE_MS.toInt()})")
        println("perf android import match 20k lines: ${resolveMs.toInt()} ms (budget ${ImportBudget.RESOLVE_MS.toInt()})")
        assertTrue("matched ${matched.size}", matched.size > 19_900)
        assertTrue("parsing a 20k-line CSV got slower: ${parseMs.toInt()} ms", parseMs < ImportBudget.PARSE_MS)
        assertTrue("matching a 20k-line CSV got slower: ${resolveMs.toInt()} ms", resolveMs < ImportBudget.RESOLVE_MS)
    }

    /** The same file without Scryfall ids: every line matches by set + collector number. */
    @Test
    fun resolve20kLinesBySetNumber() {
        val rows = CollectionCSV.parse(bigFile).rows.map { it.copy(scryfallId = null) }
        val db = TestImportCatalog.db
        ImportResolver(db, TestImportCatalog.setNames).resolve(rows.take(2_000)) // JIT warm-up
        val t0 = System.nanoTime()
        val (matched, _) = ImportResolver(db, TestImportCatalog.setNames).resolve(rows)
        val t = ms(t0)
        println("perf android import match 20k lines by set + number: ${t.toInt()} ms (budget ${ImportBudget.RESOLVE_MS.toInt()})")
        assertTrue("matched ${matched.size}", matched.size > 19_900)
        assertTrue("matching a 20k-line CSV by set + number got slower: ${t.toInt()} ms", t < ImportBudget.RESOLVE_MS)
    }
}
