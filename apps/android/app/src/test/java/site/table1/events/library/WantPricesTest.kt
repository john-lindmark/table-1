package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Want prices (contract/want-prices-2026-10-26.md) against testdata/want-prices/cases.json (iOS WantPricesTests, web wantPrices.test.ts). */
class WantPricesTest {
    private val doc = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/want-prices") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun num(o: JsonObject, k: String) = (o[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.doubleOrNull
    private fun int(o: JsonObject, k: String) = (o[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.intOrNull

    @Test fun money() {
        for (c in doc["money"]!!.jsonArray) {
            val o = c.jsonObject
            assertEquals(o["want"]!!.jsonPrimitive.content, WantPrices.money(num(o, "v")!!))
        }
    }

    @Test fun trend() {
        for (c in doc["trend"]!!.jsonArray) {
            val o = c.jsonObject
            val want = (o["want"] as? JsonObject)?.let { WantPrices.Trend(it["dir"]!!.jsonPrimitive.content, it["text"]!!.jsonPrimitive.content) }
            assertEquals(o.toString(), want, WantPrices.trend(num(o, "now"), num(o, "then"), int(o, "days")))
        }
    }

    @Test fun detail() {
        for (c in doc["detail"]!!.jsonArray) {
            val o = c.jsonObject
            assertEquals(o["want"]!!.jsonPrimitive.content,
                WantPrices.detail(o["which"]!!.jsonPrimitive.content, num(o, "max"), num(o, "now"), o["any"]!!.jsonPrimitive.boolean))
        }
    }

    @Test fun decodesTheAnswer() {
        val p = Json { ignoreUnknownKeys = true }.decodeFromString(WantPrice.serializer(),
            """{"oracle_id": "o", "card_id": null, "finish": null, "now": 1.4, "now_card_id": "c", "now_finish": "foil", "then": 1.8, "then_days": 7, "avg30": null}""")
        assertEquals(wantKey("o", null, null), p.key)
        assertEquals("▼ 22% this week", WantPrices.trend(p.now, p.then, p.thenDays)?.text)
    }
}

/** Buy on TCGplayer (contract/tcgplayer-cart-2026-10-26.md): the server's answer and the parts menu. */
class TCGplayerCartTest {
    @Test fun decodesTheAnswer() {
        val a = Json { ignoreUnknownKeys = true }.decodeFromString(TCGplayerCartAnswer.serializer(),
            """{"urls": ["https://www.tcgplayer.com/massentry?productline=Magic&c=1%20Opt"], "lines": 1, "enabled": true, "unknown": 0}""")
        assertEquals(true, a.enabled)
        assertEquals(1, a.urls.size)
    }

    @Test fun partTitles() {
        assertEquals("Part 1 of 3", TCGplayerCart.partTitle(0, 3))
        assertEquals("Part 3 of 3", TCGplayerCart.partTitle(2, 3))
    }
}
