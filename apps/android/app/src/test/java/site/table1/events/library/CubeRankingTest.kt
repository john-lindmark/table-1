package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/**
 * Cube rankings engine (contract/cube-rankings-2026-10-21.md) against the shared cases in
 * testdata/cube-ranking/cases.json, written by the reference make_cases.py; iOS CubeRankingTests and web
 * cubeRanking.test.ts read the same file.
 */
class CubeRankingTest {
    private val cases = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/cube-ranking") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject
    private val cards: Map<String, RankJob> = cases["cube"]!!.jsonObject["category"]!!.jsonObject.mapValues { RankJob.of(it.value.jsonPrimitive.content)!! }
    private val runs = cases["runs"]!!.jsonArray.map { it.jsonObject }

    private fun strings(e: JsonElement?): List<String>? = if (e == null || e is JsonNull) null else e.jsonArray.map { it.jsonPrimitive.content }
    private fun log(run: JsonObject) = run["steps"]!!.jsonArray.map { val o = it.jsonObject; RankScreen(o["s"]!!.jsonPrimitive.content, strings(o["answer"])!!) }
    private fun state(run: JsonObject, log: List<RankScreen>) =
        RankingState(run["id"]!!.jsonPrimitive.content, cards, log, run["depth"]!!.jsonPrimitive.content, run["top"]!!.jsonPrimitive.int)
    private fun cell(e: JsonElement): String = if (e is JsonNull) "null" else e.jsonPrimitive.content

    private fun checkSummary(st: RankingState, want: JsonObject, label: String) {
        assertEquals(label, (st.jobs.map { it.key } + "F").toSet(), want.keys)
        for ((key, v) in want) {
            val w = v.jsonObject
            val s = st.session(RankJob.of(key)!!)
            assertEquals("$label $key top", strings(w["top"]), s.top.map(st::id))
            assertEquals("$label $key done", w["done"]!!.jsonPrimitive.boolean, s.done)
            assertEquals("$label $key target", w["target"]!!.jsonPrimitive.int, s.target)
            assertEquals("$label $key size", w["size"]!!.jsonPrimitive.int, s.size)
            assertEquals("$label $key screens", w["screens"]!!.jsonPrimitive.int, st.knowledge.perJob[key] ?: 0)
            assertEquals("$label $key question", strings(w["question"]), s.question?.map(st::id))
            strings(w["pinned"])?.let { assertEquals("$label $key pinned", it, s.pinned.map(st::id)) }
            assertEquals("$label $key waiting", strings(w["waiting"]) ?: emptyList<String>(), s.waiting.map(st::id))
        }
    }

    /** The cube changes after a ranking finished: removed cards leave the lists and new ones wait, the order holds, and a
     *  re-rank asks only what it must until every list is whole again. */
    @Test fun cubeChange() {
        val cc = cases["cubeChange"]!!.jsonObject
        val run = runs.first { it["id"]!!.jsonPrimitive.content == cc["id"]!!.jsonPrimitive.content }
        val removed = strings(cc["removed"])!!.toSet()
        val cube = cards.filterKeys { it !in removed } + cc["added"]!!.jsonObject.mapValues { RankJob.of(it.value.jsonPrimitive.content)!! }
        val fresh = strings(cc["new"])!!.toSet()
        fun at(l: List<RankScreen>) = RankingState(cc["id"]!!.jsonPrimitive.content, cube, l, cc["depth"]!!.jsonPrimitive.content, cc["top"]!!.jsonPrimitive.int, fresh)
        val l = log(run).toMutableList()
        checkSummary(at(l), cc["before"]!!.jsonObject, "before")
        assertEquals(fresh.sorted(), at(l).waiting)
        val start = at(l)
        var st = start
        for (step in cc["steps"]!!.jsonArray.map { it.jsonObject }) {
            val job = RankJob.of(step["s"]!!.jsonPrimitive.content)!!
            val s = st.session(job)
            assertEquals("change screen ${step["at"]}", strings(step["question"]), s.question?.map(st::id))
            assertEquals(strings(step["pinned"]), s.pinned.map(st::id))
            assertEquals(strings(step["waiting"]), s.waiting.map(st::id))
            assertEquals("the list stays whole at ${step["at"]}", strings(step["top"]), s.top.map(st::id))
            val screen = RankScreen(job.key, strings(step["answer"])!!)
            st = st.appending(screen)
            l += screen
        }
        checkSummary(at(l), cc["after"]!!.jsonObject, "after")
        assertEquals(emptyList<String>(), at(l).waiting)
        assertEquals(wantRows(cc["changes"]), changeRows(RankChange.diff(start.places(), at(l).places())))
        val c = CubeChange.of(listOf("a", "B", "c"), listOf("b", "c", "d"))
        assertEquals(listOf("a") to listOf("d"), c.added to c.removed)
        assertTrue("no baseline yet: nothing to say", CubeChange.of(listOf("a"), null).isEmpty)
    }

    private fun changeRows(cs: List<RankChange>) = cs.map { listOf(it.s, it.c, it.f?.toString() ?: "null", it.to?.toString() ?: "null") }
    private fun wantRows(e: JsonElement?) = e!!.jsonArray.map { row -> row.jsonArray.map(::cell) }

    @Test fun replayEveryScreen() {
        for (run in runs) {
            val id = run["id"]!!.jsonPrimitive.content
            var st = state(run, emptyList())
            for (step in run["steps"]!!.jsonArray.map { it.jsonObject }) {
                val job = RankJob.of(step["s"]!!.jsonPrimitive.content)!!
                assertEquals(step["at"]!!.jsonPrimitive.int, st.knowledge.screens)
                val answer = strings(step["answer"])!!
                if (job == RankJob.Pick) {
                    val pk = CubeRanking.pack(id, st.knowledge)
                    assertEquals(strings(step["pack"]), pk)
                    assertEquals(strings(step["disagree"]), CubeRanking.disagreements(st.knowledge, answer[0], pk))
                    st = st.appending(RankScreen("P", answer))
                    continue
                }
                val s = st.session(job)
                assertEquals("$id screen ${step["at"]}", strings(step["question"]), s.question?.map(st::id))
                assertEquals("$id pinned ${step["at"]}", strings(step["pinned"]), s.pinned.map(st::id))
                st = st.appending(RankScreen(job.key, answer))
            }
            checkSummary(st, run["summary"]!!.jsonObject, id)
            checkSummary(state(run, log(run)), run["summary"]!!.jsonObject, "rebuilt $id")
            run["contradicted"]?.jsonObject?.let { want ->
                val got = st.knowledge.contradicted.map { (k, v) -> k.toString() to v.map { listOf(st.id(it.first), st.id(it.second)) } }.toMap()
                assertEquals(want.mapValues { (_, v) -> v.jsonArray.map { p -> strings(p)!! } }, got)
            }
        }
    }

    @Test fun compare() {
        val a = state(runs[0], log(runs[0])); val b = state(runs[1], log(runs[1]))
        for ((key, v) in cases["compare"]!!.jsonObject) {
            val job = RankJob.of(key)!!
            val w = v.jsonObject
            val c = CubeRanking.compare(a.knowledge, a.session(job), b.session(job), a.scope(job))
            assertEquals(key, w["compared"]!!.jsonPrimitive.int, c.compared)
            assertEquals(key, w["avgTenths"]!!.jsonPrimitive.int, c.avgTenths)
            assertEquals(key, w["atLeast"]!!.jsonPrimitive.boolean, c.atLeast)
            fun rows(g: List<CubeRanking.Gap>) = g.map { listOf(it.card, "${it.a}", "${it.aOut}", "${it.b}", "${it.bOut}", "${it.gap}", "${it.atLeast}") }
            assertEquals("$key biggest", wantRows(w["biggest"]), rows(c.biggest))
            assertEquals("$key one side", wantRows(w["oneSide"]), rows(c.oneSide))
        }
    }

    @Test fun whyRedoAndPickWins() {
        val run = runs[0]
        val l = log(run); val full = state(run, l)
        for (w in cases["why"]!!.jsonArray.map { it.jsonObject }) {
            val chain = CubeRanking.why(full.knowledge, l, w["hi"]!!.jsonPrimitive.content, w["lo"]!!.jsonPrimitive.content)
            val want = (w["chain"] as? JsonArray)?.map { row -> row.jsonArray.map(::cell) }
            assertEquals(want, chain?.map { listOf(it.winner, it.loser, "${it.screen}") })
        }
        for (r in cases["redo"]!!.jsonArray.map { it.jsonObject }) {
            val i = r["remove"]!!.jsonPrimitive.int
            val st = state(run, l.filterIndexed { k, _ -> k != i })
            assertEquals("redo $i", r["changesNothing"]!!.jsonPrimitive.boolean, st.knowledge.same(full.knowledge))
            val job = RankJob.of(r["session"]!!.jsonPrimitive.content)!!
            assertEquals("reask $i", r["reaskOpen"]!!.jsonPrimitive.boolean, CubeRanking.reaskOpen(st.knowledge, st.session(job), l[i].o))
            checkSummary(st, r["after"]!!.jsonObject, "after redo $i")
            assertEquals("changes $i", wantRows(r["changes"]), changeRows(RankChange.diff(full.places(), st.places())))
        }
        val runC = runs[2]; val w = cases["pickWins"]!!.jsonObject
        val lc = log(runC); val st = state(runC, lc)
        assertEquals(w["at"]!!.jsonPrimitive.int, st.knowledge.screens)
        val pk = CubeRanking.pack(runC["id"]!!.jsonPrimitive.content, st.knowledge)
        assertEquals(strings(w["pack"]), pk)
        val picked = w["picked"]!!.jsonPrimitive.content
        assertEquals(strings(w["disagree"]), CubeRanking.disagreements(st.knowledge, picked, pk))
        val removed = CubeRanking.pickWins(cards.keys, lc, picked, pk)
        assertEquals(w["removed"]!!.jsonArray.map { it.jsonPrimitive.int }, removed)
        val after = state(runC, lc.filterIndexed { k, _ -> k !in removed } + RankScreen("P", listOf(picked) + pk.filter { it != picked }))
        checkSummary(after, w["after"]!!.jsonObject, "pick wins")
        assertEquals(wantRows(w["changes"]), changeRows(RankChange.diff(st.places(), after.places())))
    }

    @Test fun contradictionAndRemovedCard() {
        val edge = cases["edge"]!!.jsonObject
        val screens = edge["log"]!!.jsonArray.map { val o = it.jsonObject; RankScreen(o["s"]!!.jsonPrimitive.content, strings(o["o"])!!) }
        val K = RankKnowledge.of(cards.keys, screens)
        val known = (0 until K.size).flatMap { x -> K.beatsSet(x).members.map { listOf(K.ids[x], K.ids[it]) } }
            .sortedWith(compareBy({ it[0] }, { it[1] }))
        assertEquals(edge["known"]!!.jsonArray.map { strings(it)!! }, known)
    }

    @Test fun estimates() {
        val est = cases["estimates"]!!.jsonObject
        for (row in est["sort"]!!.jsonArray.map { it.jsonArray }) {
            val got = CubeRanking.expectedSort(row[0].jsonPrimitive.int, row[1].jsonPrimitive.int)
            assertTrue("sort $row", abs(got - row[2].jsonPrimitive.int) <= 1)
        }
        for (row in est["merge"]!!.jsonArray.map { it.jsonArray }) {
            val got = CubeRanking.expectedMerge(row[0].jsonArray.map { it.jsonPrimitive.int }, row[1].jsonPrimitive.int)
            assertTrue("merge $row", abs(got - row[2].jsonPrimitive.int) <= 1)
        }
        assertEquals(0x811C9DC5L, CubeRanking.fnv1a(""))
        assertEquals(0xE40C292CL, CubeRanking.fnv1a("a"))
    }

    /** The ranker shows each card as the cube has it; a printing the card data lacks keeps the usual art. */
    @Test fun cardsShowInTheCubesPrinting() {
        fun p(id: String) = CatalogPrinting(id, 0, 0, "x", "1", "en", "c", "n", "", "", 1, "")
        val held = mapOf("bolt" to "sld-bolt", "opt" to "missing-opt")
        val found = mapOf("sld-bolt" to p("sld-bolt"))
        assertEquals("sld-bolt", RankingModel.asInCube(RankCard("bolt", "Lightning Bolt", p("alpha-bolt")), held, found).printing?.cardId)
        assertEquals("xln-opt", RankingModel.asInCube(RankCard("opt", "Opt", p("xln-opt")), held, found).printing?.cardId)
        assertEquals("fut-goyf", RankingModel.asInCube(RankCard("goyf", "Tarmogoyf", p("fut-goyf")), held, found).printing?.cardId)
    }
}
