package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** The Buy screen (contract/buy-2026-11-06.md) against testdata/buy/cases.json (also iOS BuyListTests and web
 *  buyList.test.ts). */
class BuyListTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/buy") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject
    private val oracles = c["oracles"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content }

    private fun s(o: JsonObject, k: String) = o[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content

    @Test fun rowsTotalsAndCalls() {
        for (x in c["cases"]!!.jsonArray.map { it.jsonObject }) {
            val name = s(x, "name")!!
            val lines = x["lines"]!!.jsonArray.map { it.jsonObject }.map { l ->
                BuyList.Line(s(l, "card_id")!!, s(l, "oracle_id"), l["any"]?.jsonPrimitive?.boolean ?: false, s(l, "board")!!, s(l, "finish")!!,
                    l["qty"]!!.jsonPrimitive.int, l["unit"]?.jsonPrimitive?.intOrNull, l["basic"]?.jsonPrimitive?.boolean ?: false)
            }
            val o = x["options"]!!.jsonObject
            val opts = BuyList.Options(o["skip_owned"]!!.jsonPrimitive.boolean, o["any_printing"]!!.jsonPrimitive.boolean, o["exact"]!!.jsonPrimitive.boolean,
                o["boards"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet())
            val owned = x["owned"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }
            val rows = BuyList.rows(lines, Holdings(owned, oracles), opts)
            assertEquals(name, x["rows"]!!.jsonArray.map { r -> r.jsonObject.let { listOf(s(it, "card_id"), s(it, "board"), s(it, "finish"), s(it, "qty"), s(it, "owned"), s(it, "buy")) } },
                rows.map { listOf(it.line.cardId, it.line.board, it.line.finish, "${it.line.qty}", "${it.owned}", "${it.buy}") })
            val t = BuyList.totals(rows)
            val w = x["totals"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }
            assertEquals(name, listOf(w["cards"], w["owned"], w["buy"], w["price"], w["owned_value"], w["total"], w["unpriced"]),
                listOf(t.cards, t.owned, t.buy, t.price, t.ownedValue, t.total, t.unpriced))
            assertEquals(name, x["calls"]!!.jsonArray.map { cl ->
                cl.jsonObject.let { it["products"]!!.jsonPrimitive.boolean to it["items"]!!.jsonArray.map { i -> i.jsonObject.let { j -> Triple(s(j, "card_id"), s(j, "oracle_id"), j["qty"]!!.jsonPrimitive.int) } } }
            }, BuyList.calls(rows, opts.exact).map { cl -> cl.products to cl.items.map { Triple(it.cardId, it.oracleId, it.qty) } })
        }
    }

    @Test fun merge() {
        for (m in c["merge"]!!.jsonArray.map { it.jsonObject }) {
            val answers = m["answers"]!!.jsonArray.map { json.decodeFromJsonElement<TCGplayerCartAnswer>(it) }
            assertEquals(s(m, "name"), json.decodeFromJsonElement<TCGplayerCartAnswer>(m["merged"]!!), BuyList.merge(answers))
        }
    }
}
