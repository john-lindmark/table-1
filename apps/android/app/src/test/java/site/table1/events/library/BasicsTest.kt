package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Basic lands are never missing (contract/basics-2026-10-24.md) against testdata/basics/cases.json (also iOS
 *  BasicsTests and web basics.test.ts). The catalog query itself is checked on iOS and web (it needs Android's SQLite). */
class BasicsTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/basics") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject
    private val basics = c["basics"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
    private val owned = c["owned"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }
    private val lists = c["lists"]!!.jsonArray.map { it.jsonObject }.map { l ->
        val entries = l["entries"]!!.jsonArray.map { it.jsonObject }.map {
            ListEntry(it["card_id"]!!.jsonPrimitive.content, it["board"]!!.jsonPrimitive.content, it["qty"]!!.jsonPrimitive.int, it["finish"]!!.jsonPrimitive.content)
        }
        val name = l["name"]!!.jsonPrimitive.content
        CardList(name, if (l["kind"]!!.jsonPrimitive.content == "deck") ListKind.Deck else ListKind.Cube, name, "modern", listOf(ListVersion(1, 0.0, "", entries)))
    }

    @Test fun neverMissingFromAList() {
        val missing = c["missing"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }
        val without = c["missingWithoutBasics"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }
        for (l in lists) {
            assertEquals(l.name, missing[l.name], l.missing(owned, basics))
            assertEquals(l.name, without[l.name], l.missing(owned, emptySet()))
        }
    }

    @Test fun stayOutOfWantsMissing() {
        val want = c["lines"]!!.jsonArray.map { it.jsonObject }.map { m ->
            MissingLine(m["card_id"]!!.jsonPrimitive.content, m["finish"]!!.jsonPrimitive.content, m["short"]!!.jsonPrimitive.int,
                m["lists"]!!.jsonArray.map { it.jsonPrimitive.content })
        }
        assertEquals(want, MissingView.lines(lists, owned, basics))
    }

    @Test fun onlyEveryCardAddsThem() {
        for (a in c["add"]!!.jsonArray.map { it.jsonObject }) {
            val l = lists.first { it.name == a["list"]!!.jsonPrimitive.content }
            val mode = if (a["mode"]!!.jsonPrimitive.content == "all") ListToCollection.Mode.All else ListToCollection.Mode.Missing
            val want = a["ops"]!!.jsonArray.map { it.jsonObject }.map {
                ListToCollection.Op(it["card_id"]!!.jsonPrimitive.content, it["finish"]!!.jsonPrimitive.content, it["delta"]!!.jsonPrimitive.int)
            }
            assertEquals("${l.name} $mode", want, ListToCollection.ops(l.entries, l.kind, owned, mode, basics = basics))
        }
    }
}
