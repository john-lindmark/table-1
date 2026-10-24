package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** A copy's price follows its condition (contract/condition-prices-2026-10-24.md) against
 *  testdata/condition-prices/cases.json (also iOS ConditionPriceTests, web conditionPrice.test.ts and the database). */
class ConditionPriceTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/condition-prices") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    @Test fun shares() {
        val percent = c["percent"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }
        for ((k, v) in percent) assertEquals(k, v, Conditions.percent(k))
        assertEquals(percent.keys, Conditions.all.toSet())
    }

    @Test fun unitCases() {
        for (u in c["unit"]!!.jsonArray.map { it.jsonObject }) {
            val nm = u["nm"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.double }
            val want = u["price"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.double }
            val cond = u["condition"]!!.jsonPrimitive.content
            assertEquals("$nm $cond", want, Conditions.price(nm, cond))
        }
    }

    @Test fun total() {
        val t = c["copies"]!!.jsonArray.map { it.jsonObject }.sumOf {
            it["qty"]!!.jsonPrimitive.int * (Conditions.price(it["nm"]!!.jsonPrimitive.doubleOrNull, it["condition"]!!.jsonPrimitive.content) ?: 0.0)
        }
        assertEquals(c["total"]!!.jsonPrimitive.double, t, 0.001)
    }

    @Test fun betterAndLabel() {
        assertTrue(Conditions.better("NM", "LP"))
        assertFalse(Conditions.better("DMG", "HP"))
        assertEquals(PriceBook.text(10.0), PriceBook.conditionText(10.0, "NM"))
        assertEquals("${PriceBook.text(9.0)} · LP (NM ${PriceBook.text(10.0)})", PriceBook.conditionText(10.0, "LP"))
        assertNull(PriceBook.conditionText(null, "LP"))
    }
}
