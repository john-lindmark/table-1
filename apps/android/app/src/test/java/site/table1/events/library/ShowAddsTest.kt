package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Added copies show before the server answers and are taken back if the call fails. Shared cases
 *  testdata/show-adds/cases.json (also iOS ShowAddsTests and web showAdds.test.ts). */
class ShowAddsTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/show-adds") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun qtys(o: kotlinx.serialization.json.JsonElement?) = o!!.jsonObject.mapValues { it.value.jsonPrimitive.int }

    @Test fun sharedCases() {
        for (k in c["cases"]!!.jsonArray.map { it.jsonObject }) {
            val name = k["name"]!!.jsonPrimitive.content
            val startItems = qtys(k["items"])
            val startAllocs = qtys(k["allocs"])
            var items = startItems.mapValues { (key, qty) ->
                val p = key.split("|")
                CollectionItem(p[0], p[1], p[2], p[3], qty, 7)
            }
            var allocs = startAllocs.mapValues { (key, qty) ->
                val p = key.split("|")
                BinderAlloc(p[0], p[1], p[2], p[3], p[4], qty, 3)
            }
            val ops = k["ops"]!!.jsonArray.map { it.jsonObject }.map { o ->
                CollectionOp(
                    o["card_id"]!!.jsonPrimitive.content, o["finish"]?.jsonPrimitive?.content ?: "nonfoil",
                    o["condition"]?.jsonPrimitive?.content ?: "NM", o["lang"]?.jsonPrimitive?.content ?: "en",
                    o["delta"]?.jsonPrimitive?.int, o["qty"]?.jsonPrimitive?.int, o["binder_id"]?.jsonPrimitive?.content,
                )
            }
            val shown = k["shown"]!!.jsonObject

            var r = shiftAdds(items, ops, 1)
            items = r.first
            allocs = shiftAllocs(allocs, r.second)
            assertEquals(name, qtys(shown["items"]), items.mapValues { it.value.qty })
            assertEquals(name, qtys(shown["allocs"]), allocs.mapValues { it.value.qty })
            // A held item keeps its seq, so the sync row that follows is never skipped as older.
            for (key in startItems.keys) assertEquals(name, 7L, items[key]?.seq)

            r = shiftAdds(items, ops, -1)
            assertEquals("$name: taken back", startItems, r.first.mapValues { it.value.qty })
            assertEquals("$name: taken back", startAllocs, shiftAllocs(allocs, r.second).mapValues { it.value.qty })
        }
    }
}
