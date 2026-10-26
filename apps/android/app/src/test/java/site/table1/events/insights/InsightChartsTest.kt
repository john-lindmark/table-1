package site.table1.events.insights

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/*
 * Insights chart maths (contract/insights-2026-10-24.md). Every answer comes from testdata/insight-charts/cases.json,
 * written by the Python reference there; iOS InsightChartsTests.swift and the web's insightCharts.test.ts read it too.
 */
class InsightChartsTest {
    private val cases: JsonObject = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/insight-charts") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun list(name: String) = cases[name]!!.jsonArray.map { it.jsonObject }
    private fun doubles(e: kotlinx.serialization.json.JsonElement) = e.jsonArray.map { it.jsonPrimitive.double }

    @Test fun ticks() = list("ticks").forEach { c ->
        val i = doubles(c["in"]!!)
        val want = doubles(c["out"]!!)
        val got = InsightCharts.ticks(i[0], i[1], i[2].toInt())
        assertEquals("$i", want.size, got.size)
        want.zip(got).forEach { (w, g) -> assertEquals("$i", w, g, 1e-9) }
    }

    @Test fun segments() = list("segments").forEach { c ->
        val input = c["in"]!!.jsonArray.map { if (it is JsonNull) null else it.jsonPrimitive.double }
        val want = c["out"]!!.jsonArray.map { seg -> seg.jsonArray.map { p -> p.jsonArray.let { it[0].jsonPrimitive.int to it[1].jsonPrimitive.double } } }
        assertEquals(want, InsightCharts.segments(input))
    }

    @Test fun heat() = list("heat").forEach { c ->
        val i = c["in"]!!.jsonArray.map { it.jsonPrimitive.int }
        val o = c["out"]!!.jsonObject
        val want = InsightCharts.Heat(o["label"]!!.jsonPrimitive.content, o["tone"]!!.jsonPrimitive.content, o["strength"]!!.jsonPrimitive.double,
            o["dim"]!!.jsonPrimitive.content == "true", o["ink"]!!.jsonPrimitive.content == "true")
        assertEquals("$i", want, InsightCharts.heat(i[0], i[1]))
    }

    @Test fun wilson() = list("wilson").forEach { c ->
        val i = c["in"]!!.jsonArray.map { it.jsonPrimitive.int }
        val want = doubles(c["out"]!!)
        val (lo, hi) = InsightCharts.wilson(i[0], i[1])
        assertEquals(want[0], lo, 1e-6); assertEquals(want[1], hi, 1e-6)
    }

    @Test fun fit() = list("fit").forEach { c ->
        val i = c["in"]!!.jsonArray
        val got = InsightCharts.fit(doubles(i[0]), doubles(i[1]))
        val out = c["out"]
        if (out == null || out is JsonNull) assertNull(got)
        else { assertEquals(out.jsonObject["a"]!!.jsonPrimitive.double, got!!.first, 1e-7); assertEquals(out.jsonObject["b"]!!.jsonPrimitive.double, got.second, 1e-7) }
    }

    @Test fun spread() = list("spread").forEach { c ->
        val i = c["in"]!!.jsonArray
        val got = InsightCharts.spread(doubles(i[0]), i[1].jsonPrimitive.double, i[2].jsonPrimitive.double, i[3].jsonPrimitive.double)
        val want = doubles(c["out"]!!)
        assertEquals(want.size, got.size)
        want.zip(got).forEach { (w, g) -> assertEquals(w, g, 1e-6) }
    }

    @Test fun labels() {
        list("pct").forEach { c -> assertEquals(c["out"]!!.jsonPrimitive.content, InsightCharts.pct(c["in"]!!.jsonPrimitive.doubleOrNull)) }
        list("pct1").forEach { c -> assertEquals(c["out"]!!.jsonPrimitive.content, InsightCharts.pct1(c["in"]!!.jsonPrimitive.doubleOrNull)) }
        list("delta").forEach { c -> assertEquals(c["out"]!!.jsonPrimitive.content, InsightCharts.delta(c["in"]!!.jsonPrimitive.doubleOrNull)) }
    }

    @Test fun months() = list("months").forEach { c ->
        val i = c["in"]!!.jsonArray
        val want = c["out"]!!.jsonArray.map { it.jsonArray[0].jsonPrimitive.int to it.jsonArray[1].jsonPrimitive.content }
        assertEquals(want, InsightCharts.months(i[0].jsonPrimitive.content, i[1].jsonPrimitive.int))
    }
}
