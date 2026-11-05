package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Sideboard guides (contract/sideboard-guide-2026-11-04.md) against testdata/sideboard-guide/cases.json, and the
 *  printed page against guide.html byte for byte (also iOS SideboardGuideTests and web sideboardGuide.test.ts). */
class SideboardGuideTest {
    private val dir = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/sideboard-guide") }.first { it.isDirectory }
    private val c = Json.parseToJsonElement(File(dir, "cases.json").readText()).jsonObject
    private val json = Json { ignoreUnknownKeys = true }
    private val guide = json.decodeFromJsonElement(SideboardGuide.serializer(), c["guide"]!!)
    private val lines = lines(c["lines"]!!)

    private fun lines(e: kotlinx.serialization.json.JsonElement) = e.jsonArray.map { it.jsonObject }.map {
        SideboardRules.Line(it.s("oracle"), it.s("name"), it.s("board"), it["qty"]!!.jsonPrimitive.int)
    }
    private fun JsonObject.s(k: String) = this[k]!!.jsonPrimitive.content
    private fun cards(e: kotlinx.serialization.json.JsonElement?) = e?.jsonArray?.map { GuideCard(it.jsonArray[0].jsonPrimitive.content, it.jsonArray[1].jsonPrimitive.int) } ?: emptyList()

    private fun key(i: SideboardRules.Issue) = when (i) {
        is SideboardRules.Issue.Gone -> "gone:${if (i.side == GuideSide.In) "in" else "out"}:${i.oracle}"
        is SideboardRules.Issue.InOver -> "in_over:${i.oracle}:${i.have}"
        is SideboardRules.Issue.OutOver -> "out_over:${i.oracle}:${i.have}"
        is SideboardRules.Issue.Considering -> "considering:${i.oracle}:${i.qty}"
        is SideboardRules.Issue.BelowMin -> "below_min:${i.deck}:${i.min}"
    }
    private fun key(o: JsonObject) = when (o.s("code")) {
        "gone" -> "gone:${o.s("side")}:${o.s("oracle")}"
        "in_over" -> "in_over:${o.s("oracle")}:${o.s("have")}"
        "out_over" -> "out_over:${o.s("oracle")}:${o.s("have")}"
        "considering" -> "considering:${o.s("oracle")}:${o.s("qty")}"
        else -> "below_min:${o.s("deck")}:${o.s("min")}"
    }

    @Test fun formats() {
        for ((f, v) in c["has_guide"]!!.jsonObject) assertEquals(f, v.jsonPrimitive.boolean, SideboardRules.hasGuide(f))
        for ((f, v) in c["deck_min"]!!.jsonObject) assertEquals(f, if (v is JsonNull) null else v.jsonPrimitive.int, SideboardRules.deckMin(f))
    }

    @Test fun decodesTheWire() {
        assertEquals(listOf("Boros Energy", "Esper Goryo's & <friends>", "Mirror"), guide.matchups.map { it.name })
        assertEquals(12, guide.matchups[0].archetype)
        assertEquals(listOf(GuideCard("o-fury", 2), GuideCard("o-blood", 1)), guide.matchups[0].ins)
    }

    @Test fun check() {
        for (x in c["check"]!!.jsonArray.map { it.jsonObject }) {
            val id = x.s("matchup")
            val m = guide.matchup(id) ?: Matchup(id, id, ins = cards(x["in"]), outs = cards(x["out"]))
            val got = SideboardRules.check(m, lines, x.s("format"))
            val want = x["expect"]!!.jsonObject
            val label = "$id ${x.s("format")}"
            assertEquals(label, want["in"]!!.jsonPrimitive.int, got.ins)
            assertEquals(label, want["out"]!!.jsonPrimitive.int, got.outs)
            assertEquals(label, want["deck"]!!.jsonPrimitive.int, got.deck)
            assertEquals(label, want.s("label"), got.label)
            assertEquals(label, want["issues"]!!.jsonArray.map { key(it.jsonObject) }, got.issues.map(::key))
        }
    }

    @Test fun sideboardAndUses() {
        assertEquals(c["sideboard_count"]!!.jsonPrimitive.int, SideboardRules.sideboardCount(lines))
        for (x in c["over_sideboard"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(x["expect"]!!.jsonPrimitive.intOrNull, SideboardRules.overSideboard(lines(x["lines"]!!), x.s("format")))
        }
        assertEquals(c["uses"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }, SideboardRules.uses(guide))
    }

    @Test fun setKeepsOrder() {
        val m = Matchup("a", "A").set("x", 2, GuideSide.In).set("y", 1, GuideSide.In).set("x", 3, GuideSide.In)
        assertEquals(listOf(GuideCard("x", 3), GuideCard("y", 1)), m.ins)
        assertEquals(listOf(GuideCard("y", 1)), m.set("x", 0, GuideSide.In).ins)
    }

    @Test fun print() {
        val p = c["print"]!!.jsonObject
        val r = SideboardRules.printModel("Izzet Murktide", "Modern", "2026-11-04", lines, guide, "modern")
        assertEquals(p["sheets"]!!.jsonPrimitive.int, r.sheets)
        assertEquals(p["warnings"]!!.jsonArray.map { "${it.jsonObject.s("code")}:${it.jsonObject.s("qty")}" }, r.warnings.map { "${it.code}:${it.qty}" })
        assertEquals(p["model"]!!.jsonObject["sideboard"]!!.jsonArray.map { "${it.jsonArray[0].jsonPrimitive.content} ${it.jsonArray[1].jsonPrimitive.content}" },
            r.model.sideboard.map { "${it.first} ${it.second}" })
        assertEquals(File(dir, "guide.html").readText(), SideboardRules.html(r.model))
    }

    @Test fun sheets() {
        for (x in c["sheets"]!!.jsonArray.map { it.jsonObject }) {
            val n = x["matchups"]!!.jsonPrimitive.int
            val m = SideboardRules.PrintModel("", "", "", List(15) { 1 to "x" },
                List(n) { SideboardRules.PrintMatchup("m", List(5) { 1 to "a" }, List(5) { 1 to "b" }, "x".repeat(120)) })
            assertEquals("$n", x["expect"]!!.jsonPrimitive.int, SideboardRules.sheets(m))
        }
    }

    @Test fun listWireCarriesTheGuide() {
        val w = json.decodeFromString(ListWire.serializer(),
            """{"id":"d","kind":"deck","name":"D","format":"modern","versions":[{"version":1,"note":"","at":0,"entries":[]}],"guide":${c["guide"]}}""")
        assertEquals(guide, w.toList()!!.guide)
        assertEquals(guide, json.decodeFromString(ListWire.serializer(), json.encodeToString(ListWire.serializer(), ListWire.of(w.toList()!!))).guide)
    }
}
