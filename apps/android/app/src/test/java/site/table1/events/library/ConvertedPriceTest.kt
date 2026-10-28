package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Converted prices (contract/converted-prices-2026-10-28.md) against testdata/converted-prices/cases.json
 *  (also iOS ConvertedPriceTests, web convertedPrice.test.ts and the database). */
class ConvertedPriceTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/converted-prices") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    @Test fun sharedRows() {
        val rows = c["rows"]!!.jsonArray
        assertTrue(rows.isNotEmpty())
        for (r in rows.map { it.jsonObject }) {
            val row = r["row"]!!.jsonArray.map { if (it is JsonNull) null else it.jsonPrimitive.doubleOrNull }
            val finish = r["finish"]!!.jsonPrimitive.content
            assertEquals("$r", r["converted"]!!.jsonPrimitive.boolean, PriceBook.converted(row, finish))
            val usd = r["usd"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.doubleOrNull }
            assertEquals("$r", usd, row.getOrNull(when (finish) { "foil" -> 1; "etched" -> 2; else -> 0 }))
        }
    }

    @Test fun mark() {
        assertEquals("≈ $7,992.55", PriceBook.marked("$7,992.55", true))
        assertEquals("≈ $7,992.55 · from Cardmarket", PriceBook.marked("$7,992.55", true, source = true))
        assertEquals("$647.32", PriceBook.marked("$647.32", false, source = true))
        assertNull(PriceBook.marked(null, true))
    }
}
