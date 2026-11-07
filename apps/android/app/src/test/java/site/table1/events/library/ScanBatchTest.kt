package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.util.Locale

/** Scan from the Collection: the scanned list as Add to lines, and each row's price line
 *  (contract/trades-2026-10-16.md § Scanning; testdata/scan-batch/cases.json, also iOS ScanBatchTests). */
class ScanBatchTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/scan-batch") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun s(o: JsonObject, k: String) = o[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content

    @Test fun scannedCardsBecomeAddToLines() {
        for (x in c["lines"]!!.jsonArray.map { it.jsonObject }) {
            val got = ScanBatch.linesOf(x["scanned"]!!.jsonArray.map { it.jsonObject }.map {
                CardVersion(s(it, "card")!!, s(it, "finish")!!, s(it, "condition")!!, s(it, "lang")!!, qty = 1)
            })
            assertEquals(s(x, "name"), x["lines"]!!.jsonArray.map { it.jsonObject }.map {
                "${s(it, "card")}|${s(it, "finish")}|${s(it, "condition")}|${s(it, "lang")}|${it["qty"]!!.jsonPrimitive.int}"
            }, got.map { "${it.cardId}|${it.finish}|${it.condition}|${it.lang}|${it.qty}" })
        }
    }

    @Test fun priceLine() {
        val was = Locale.getDefault()
        Locale.setDefault(Locale.US)
        try {
            for (x in c["priceLine"]!!.jsonArray.map { it.jsonObject }) {
                assertEquals(s(x, "text"), ScanBatch.priceLine(x["usd"]!!.jsonPrimitive.doubleOrNull, x["loaded"]!!.jsonPrimitive.boolean,
                    x["converted"]!!.jsonPrimitive.boolean))
            }
        } finally { Locale.setDefault(was) }
    }

    @Test fun total() {
        for (x in c["total"]!!.jsonArray.map { it.jsonObject }) {
            val want = x["total"]!!.takeIf { it !is JsonNull }?.jsonPrimitive?.double
            assertEquals(want, ScanBatch.total(x["prices"]!!.jsonArray.map { it.jsonPrimitive.doubleOrNull }))
        }
    }
}
