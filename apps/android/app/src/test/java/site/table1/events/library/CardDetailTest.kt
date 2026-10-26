package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/** Card detail's rules (CardDetail.kt) against testdata/card-detail/cases.json (also iOS CardDetailTests and web
 *  cardDetail.test.ts). */
class CardDetailTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/card-detail") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun JsonObject.str(k: String) = this[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content
    private fun version(o: JsonObject) = CardVersion(o.str("card_id")!!, o.str("finish")!!, o.str("condition") ?: "NM", o.str("lang") ?: "en",
        o.str("board"), o["qty"]?.jsonPrimitive?.int ?: 0)

    private val printings = c["printings"]!!.jsonArray.map { it.jsonObject }.let { ps ->
        ps.mapIndexed { i, p ->
            CatalogPrinting(p.str("card_id")!!, 0, ps.size - i, p.str("set")!!, "${i + 1}", p.str("lang")!!, "c", p.str("finishes")!!,
                p.str("released_at")!!, "", 1, "", p["original"]!!.jsonPrimitive.boolean)
        }
    }
    private val byId = printings.associateBy { it.cardId }

    @Test fun repoint() {
        for (r in c["repoint"]!!.jsonArray.map { it.jsonObject }) {
            val a = CardAttribute.entries.first { it.wire == r.str("attribute") }
            assertEquals(r.str("name"), version(r["to"]!!.jsonObject),
                CardDetailRules.repoint(version(r["from"]!!.jsonObject), a, r.str("value")!!, byId[r.str("value")]))
        }
    }

    @Test fun ops() {
        for (o in c["ops"]!!.jsonArray.map { it.jsonObject }) {
            val v = version(o["item"]!!.jsonObject)
            val item = CollectionItem(v.cardId, v.finish, v.condition, v.lang, v.qty, 0)
            val places = o["places"]!!.jsonArray.map { it.jsonObject }.map { it.str("place")!! to it["qty"]!!.jsonPrimitive.int }
            val got = CardDetailRules.ops(item, places, version(o["to"]!!.jsonObject), o["qty"]!!.jsonPrimitive.int, o.str("from"))
            val want = (o["ops"] as? kotlinx.serialization.json.JsonArray)?.map { it.jsonObject }?.map {
                CollectionOp(it.str("card_id")!!, it.str("finish")!!, it.str("condition")!!, it.str("lang")!!, delta = it["delta"]!!.jsonPrimitive.int,
                    binderId = it.str("binder_id"))
            }
            assertEquals(o.str("name"), want, got)
        }
    }

    @Test fun views() {
        for (v in c["views"]!!.jsonArray.map { it.jsonObject }) {
            val name = v.str("name")
            val versions = CardDetailRules.ordered(v["versions"]!!.jsonArray.map { version(it.jsonObject) }, printings)
            assertEquals(name, v["order"]!!.jsonArray.map { it.jsonPrimitive.content }, versions.map { it.id })
            assertEquals(name, v.str("main"), CardDetailRules.main(versions)?.id)
            assertEquals(name, v["shows_finish"]!!.jsonPrimitive.boolean, CardDetailRules.showsFinish(versions, byId))
            val shared = v["shared"]!!.jsonObject
            assertEquals("$name: set", shared.str("set"), CardDetailRules.shared(versions) { it.cardId })
            assertEquals("$name: language", shared.str("language"), CardDetailRules.shared(versions) { it.lang })
            assertEquals("$name: condition", shared.str("condition"), CardDetailRules.shared(versions) { it.condition })
            assertEquals("$name: finish", shared.str("finish"), CardDetailRules.shared(versions) { it.finish })
        }
    }

    @Test fun fresh() {
        val f = c["fresh"]!!.jsonObject
        assertEquals(version(f["version"]!!.jsonObject), CardDetailRules.fresh(printings, f.str("condition")!!, f.str("lang")!!))
    }

    @Test fun newEdition() {
        val n = c["new_edition"]!!.jsonObject
        assertEquals(version(n["edition"]!!.jsonObject), CardDetailRules.newEdition(version(n["from"]!!.jsonObject)))
        for (e in c["editions"]!!.jsonArray.map { it.jsonObject }) {
            val a = CardAttribute.entries.first { it.wire == e.str("attribute") }
            val to = CardDetailRules.repoint(version(e["edition"]!!.jsonObject), a, e.str("value")!!, byId[e.str("value")])
            assertEquals(e.str("name"), version(e["to"]!!.jsonObject), to)
            assertEquals(e.str("name"), e["is_new"]!!.jsonPrimitive.boolean,
                CardDetailRules.isNew(to, e["versions"]!!.jsonArray.map { version(it.jsonObject) }))
        }
    }

    @Test fun addLines() {
        for (a in c["add_lines"]!!.jsonArray.map { it.jsonObject }) {
            val got = CardDetailRules.addLines(a["in_view"]!!.jsonArray.map { version(it.jsonObject) }, version(a["current"]!!.jsonObject),
                a["all"]!!.jsonPrimitive.boolean)
            assertEquals(a.str("name"), a["lines"]!!.jsonArray.map { version(it.jsonObject) }, got)
        }
    }

    @Test fun stepIntoUnsortedHasNoBinder() {
        val v = CardVersion("lea", "nonfoil")
        assertNull(CardDetailRules.step(v, 1, UNSORTED).binderId)
        assertEquals("b1", CardDetailRules.step(v, -1, "b1").binderId)
    }
}
