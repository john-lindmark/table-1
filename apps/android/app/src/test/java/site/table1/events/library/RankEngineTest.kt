package site.table1.events.library

import android.app.Application
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.BufferedReader
import java.io.File

/**
 * The server's engine file (library/RankEngine.kt; contract/cube-rankings-2026-10-21.md § The engine as a file):
 * testdata/cube-ranking/rank-engine.js, the file tools/rank-engine/build.mjs last built, replays every shared run through
 * RankingState with the file deciding. QuickJS's native library has no JVM build, so here the same file runs in Node
 * behind [RankJs] (skipped without node); tools/rank-engine/build.mjs runs it in a bare context like QuickJS's.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RankEngineTest {
    private val dir = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/cube-ranking") }.first { it.isDirectory }
    private val cases = Json.parseToJsonElement(File(dir, "cases.json").readText()).jsonObject
    private val cards: Map<String, RankJob> = cases["cube"]!!.jsonObject["category"]!!.jsonObject.mapValues { RankJob.of(it.value.jsonPrimitive.content)!! }
    private val code = File(dir, "rank-engine.js").readText()

    /** Node reading one line of JavaScript at a time and answering with JSON of its value. */
    private class NodeJs : RankJs {
        private val p = ProcessBuilder("node", "-e", """
            const rl = require("readline").createInterface({ input: process.stdin });
            rl.on("line", (l) => { let v; try { v = { v: (0, eval)(JSON.parse(l)) }; } catch (e) { v = { e: String(e) }; }
              process.stdout.write(JSON.stringify(v === undefined ? {} : v) + "\n"); });
        """.trimIndent()).redirectErrorStream(true).start()
        private val out = p.outputStream.bufferedWriter()
        private val inp: BufferedReader = p.inputStream.bufferedReader()
        override fun eval(code: String): Any? {
            out.write(Json.encodeToString(kotlinx.serialization.serializer<String>(), code)); out.newLine(); out.flush()
            val r = Json.parseToJsonElement(inp.readLine()).jsonObject
            r["e"]?.let { throw IllegalStateException(it.jsonPrimitive.content) }
            val v = r["v"] ?: return null
            if (v is JsonNull) return null
            if (v !is kotlinx.serialization.json.JsonPrimitive) return v.toString()
            val prim = v.jsonPrimitive
            return when {
                prim.isString -> prim.content
                prim.content == "true" || prim.content == "false" -> prim.boolean
                else -> prim.content.toDouble()
            }
        }
        override fun close() { p.destroy() }
    }

    private fun nodeThere() = runCatching { ProcessBuilder("node", "--version").start().waitFor() == 0 }.getOrDefault(false)
    private fun manifest(rules: String, api: Int = RankEngine.API) = RankEngine.Manifest(api, rules, "rank-test", "rank-test.js", "")
    private fun strings(e: JsonElement?): List<String>? = if (e == null || e is JsonNull) null else e.jsonArray.map { it.jsonPrimitive.content }

    @After fun unload() = RankEngine.unload()

    @Test fun rulesMatchTheReference() = assertEquals(cases["rules"]!!.jsonPrimitive.content, CubeRanking.RULES)

    @Test fun theFileReplaysEveryRun() {
        assumeTrue("node not installed", nodeThere())
        assertTrue(RankEngine.use(manifest(CubeRanking.RULES), code, "test", force = true) { NodeJs() })
        for (run in cases["runs"]!!.jsonArray.map { it.jsonObject }) {
            val label = run["id"]!!.jsonPrimitive.content.takeLast(2)
            var st = RankingState(run["id"]!!.jsonPrimitive.content, cards, emptyList(), run["depth"]!!.jsonPrimitive.content, run["top"]!!.jsonPrimitive.int)
            assertNotNull("run $label runs in the file", st.js)
            for ((i, e) in run["steps"]!!.jsonArray.withIndex()) {
                val step = e.jsonObject
                val s = step["s"]!!.jsonPrimitive.content
                if (s != "P") {
                    val session = st.session(RankJob.of(s)!!)
                    assertEquals("run $label step $i", strings(step["question"]), session.question?.map(st::id))
                    assertEquals("run $label step $i check", step["check"]?.jsonPrimitive?.boolean ?: false, session.check)
                }
                st = st.appending(RankScreen(s, strings(step["answer"])!!))
                assertNotNull(st.js)
            }
            for ((job, v) in run["summary"]!!.jsonObject) {
                val want = v.jsonObject
                val s = st.session(RankJob.of(job)!!)
                assertEquals("run $label $job top", strings(want["top"]), s.top.map(st::id))
                assertEquals("run $label $job done", want["done"]!!.jsonPrimitive.boolean, s.done)
                assertEquals("run $label $job checked", want["checked"]!!.jsonPrimitive.int, s.checked)
                assertEquals("run $label $job question", strings(want["question"]), s.question?.map(st::id))
            }
        }
    }

    @Test fun ourOwnRulesKeepOurEngine() {
        assertFalse(RankEngine.use(manifest(CubeRanking.RULES), code, "test") { error("not started") })
        assertFalse(RankEngine.use(manifest("2026-01-01"), code, "test") { error("not started") })
        assertFalse(RankEngine.active)
        assertNull(RankingState("x", cards, emptyList(), "half", 20).js)
    }

    @Test fun anotherApiOrABrokenFileIsRefused() {
        assumeTrue("node not installed", nodeThere())
        assertFalse(RankEngine.use(manifest("2099-01-01", api = RankEngine.API + 1), code, "test") { NodeJs() })
        assertFalse(RankEngine.use(manifest("2099-01-01"), "globalThis.T1Rank = {api: 1, rules: '2099-01-01', selfTest() { return false }}", "test") { NodeJs() })
        assertFalse(RankEngine.use(manifest("2099-01-01"), "this is not javascript", "test") { NodeJs() })
        // A file built from other rules than its manifest names.
        assertFalse(RankEngine.use(manifest("2099-01-01"), code, "test") { NodeJs() })
        assertFalse(RankEngine.active)
    }
}
