package site.table1.events.insights

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The Limited page's cards and search, the grid's Overall column, mana symbols and pasted event codes, against the
 *  shared cases iOS and web check too (testdata/insights/limited-home.json, overall.json, testdata/mana-symbols,
 *  testdata/join-code). */
class LimitedCardsTest {
    private val top = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "testdata").isDirectory }
    private val json = Json { ignoreUnknownKeys = true }
    private fun read(path: String) = json.parseToJsonElement(File(top, "testdata/$path").readText()).jsonObject
    private fun str(o: JsonObject, k: String) = o[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull
    private fun dbl(o: JsonObject, k: String) = o[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.doubleOrNull

    private fun card(o: JsonObject, rated: Boolean = true) = LCard(n = str(o, "n")!!, r = if (rated) str(o, "r") else null, col = str(o, "col"),
        gih = dbl(o, "gih"), gih_n = o["gih_n"]!!.jsonPrimitive.int, oh = dbl(o, "oh"), iwd = dbl(o, "iwd"), ata = dbl(o, "ata"), deck = 0.0)

    @Test fun limitedCardsSharedCases() {
        val f = read("insights/limited-home.json")
        assertEquals(f["top"]!!.jsonPrimitive.int, LimitedCards.TOP)
        assertEquals(f["others_max"]!!.jsonPrimitive.int, LimitedCards.OTHERS_MAX)
        assertEquals(f["min_query"]!!.jsonPrimitive.int, LimitedCards.MIN_QUERY)
        val avg = f["avg"]!!.jsonPrimitive.doubleOrNull!!
        val raw = f["cards"]!!.jsonArray.map { it.jsonObject }
        val cards = raw.map { card(it) }
        for (c in f["filters"]!!.jsonArray.map { it.jsonObject }) {
            val unrated = c["unrated"]?.jsonPrimitive?.booleanOrNull == true
            val input = if (unrated) raw.take(12).map { card(it, rated = false) } else cards
            fun picks(k: String) = c[k]!!.jsonArray.map { it.jsonPrimitive.content }
            val got = LimitedCards.cards(input, str(c, "sort")!!, picks("rarity"), picks("color")).map { it.n }
            assertEquals(str(c, "name"), c["want"]!!.jsonArray.map { it.jsonPrimitive.content }, got)
        }
        val labels = f["labels"]!!.jsonObject
        for (l in labels["rarity"]!!.jsonArray.map { it.jsonObject }) {
            val picked = l["picked"]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals(picked.toString(), str(l, "want"), LimitedCards.rarityLabel(picked))
        }
        for (l in labels["color"]!!.jsonArray.map { it.jsonObject }) {
            val picked = l["picked"]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals(picked.toString(), str(l, "want"), LimitedCards.colorLabel(picked))
        }
        assertEquals(listOf("U"), LimitedCards.toggle(listOf("W", "U"), "W"))
        assertEquals(emptyList<String>(), LimitedCards.toggle(listOf("W"), LimitedCards.ANY))
        for (v in f["values"]!!.jsonArray.map { it.jsonObject }) {
            val want = v["want"]!!.jsonObject
            val got = LimitedCards.value(cards.first { it.n == str(v, "card") }, str(v, "sort")!!, avg)
            assertEquals("${str(v, "card")} ${str(v, "sort")}", str(want, "value") to str(want, "vs"), got)
        }
        val others = f["others"]!!.jsonArray.map { o -> str(o.jsonObject, "key")!! to o.jsonObject["cards"]!!.jsonArray.map { str(it.jsonObject, "n")!! } }
        for (s in f["search"]!!.jsonArray.map { it.jsonObject }) {
            val want = s["want"]!!.jsonObject
            val (here, elsewhere) = LimitedCards.search(str(s, "query")!!, cards.map { it.n }, others)
            assertEquals(str(s, "query"), want["here"]!!.jsonArray.map { it.jsonPrimitive.content }, here)
            assertEquals(str(s, "query"), want["elsewhere"]!!.jsonArray.map { p -> p.jsonArray[0].jsonPrimitive.content to p.jsonArray[1].jsonPrimitive.content }, elsewhere)
        }
    }

    @Test fun overallSharedCases() {
        val f = read("insights/overall.json")
        val share = f["share"]!!.jsonArray.map { s ->
            val o = s.jsonObject
            ShareRow(a = o["a"]!!.jsonPrimitive.int, share = 0.0, decks = 0, top8 = 0, rec = o["rec"]?.takeIf { it !is JsonNull }?.jsonArray?.map { it.jsonPrimitive.int })
        }
        val m = json.decodeFromJsonElement(Matchups.serializer(), f["matchups"]!!)
        for (c in f["cases"]!!.jsonArray.map { it.jsonObject }) {
            val a = c["a"]!!.jsonPrimitive.int
            val want = c["want"]?.takeIf { it !is JsonNull }?.jsonObject
            val got = LimitedCards.overall(share, m, a)
            assertEquals("$a", want?.let { listOf(it["wins"]!!.jsonPrimitive.int, it["losses"]!!.jsonPrimitive.int, it["draws"]!!.jsonPrimitive.int) },
                got?.let { listOf(it.wins, it.losses, it.draws) })
            assertEquals("$a", want?.let { str(it, "from") }, got?.let { if (it.fromMeta) "meta" else "grid" })
        }
    }

    @Test fun manaSymbolsSharedCases() {
        val f = read("mana-symbols/cases.json")
        for (c in f["cases"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(str(c, "cost"), c["want"]!!.jsonArray.map { it.jsonPrimitive.content }, ManaSymbols.parse(str(c, "cost")!!))
        }
        val symbols = f["symbols"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
        assertEquals(symbols, ManaSymbols.names)
        assertTrue(symbols.all { File(top, "apps/android/app/src/main/res/drawable/mana_${it.lowercase()}.xml").isFile })
    }

    @Test fun joinCodeSharedCases() {
        val f = read("join-code/cases.json")
        for (c in f["cases"]!!.jsonArray.map { it.jsonObject }) {
            val want = c["want"]?.takeIf { it !is JsonNull }?.jsonObject
            val got = when (val j = JoinCode.parse(str(c, "text"))) {
                is JoinCode.Code -> listOf("code", j.code, null)
                is JoinCode.Qr -> listOf("qr", j.code, j.secret)
                null -> null
            }
            assertEquals(str(c, "text"), want?.let { listOf(str(it, "kind"), str(it, "code"), str(it, "secret")) }, got)
        }
    }
}
