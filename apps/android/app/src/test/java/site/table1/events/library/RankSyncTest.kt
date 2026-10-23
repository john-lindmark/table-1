package site.table1.events.library

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * Saving a ranking (RankSync.kt) against the shared cases in testdata/ranking-save/cases.json (written by the reference
 * make_cases.py; iOS RankSyncTests and web rankSync.test.ts read the same file), then RankSaver against a fake server that
 * refuses stale pushes the way cube_ranking_push does (migration 20261022180000_ranking_push_guard.sql).
 */
class RankSyncTest {
    private val cases = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/ranking-save") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject["cases"]!!.jsonArray.map { it.jsonObject }

    private fun screens(e: kotlinx.serialization.json.JsonElement?) = Json.decodeFromJsonElement(ListSerializer(RankScreen.serializer()), e!!)
    private fun keys(l: List<RankScreen>) = l.map(RankSync::key)

    @Test fun sharedCases() {
        assertTrue(cases.size >= 16)
        for (c in cases) {
            val name = c["name"]!!.jsonPrimitive.content
            val want = c["want"]!!.jsonObject
            val p = RankSync.plan(screens(c["server"]), screens(c["adds"]), screens(c["drops"]))
            assertEquals(name, keys(screens(want["log"])), keys(p.log))
            assertEquals(name, keys(screens(want["add"])), keys(p.add))
            assertEquals(name, keys(screens(want["drop"])), keys(p.drop))
            assertEquals(name, want["keep"]!!.jsonPrimitive.int, p.keep)
            assertEquals(name, want["removed"]!!.jsonPrimitive.int, p.removed)
        }
    }

    @Test fun settlingKeepsWhatWasDoneMeanwhile() {
        val a = RankScreen("W", listOf("a", "b"), 1.0); val b = RankScreen("W", listOf("c", "d"), 2.0)
        val after = RankPending(adds = listOf(a, b), drops = listOf(a)).settle(RankPending.Op("x", 3, 9, 1, 0, 0))
        assertEquals(listOf(b), after.adds)
        assertEquals(listOf(a), after.drops)
    }

    @Test fun pendingSurvivesARelaunchOnDisk() {
        val dir = Files.createTempDirectory("rank-pending").toFile()
        val p = RankPending(adds = listOf(RankScreen("W", listOf("a", "b"), 1.0)), drops = listOf(RankScreen("U", listOf("c", "d"), 2.0)))
        RankPendingFile(dir, "R1").save(p)
        assertEquals(p, RankPendingFile(dir, "r1").load())
        RankPendingFile(dir, "R1").save(RankPending())
        assertTrue(RankPendingFile(dir, "R1").load().isEmpty)
    }

    // ── RankSaver against a fake server (2026-10-23: two wipes of a 500-screen ranking) ──

    private data class Row(val rev: Int, val screens: Int)
    private data class Detail(val rev: Int, val log: List<RankScreen>)
    private class Conflict : Exception("This ranking changed on another device")

    private var n = 0
    private fun screen(s: String = "W") = RankScreen(s, listOf("card-$n-a", "card-${n}-b"), 1_000_000.0 + n++)

    private class Fake(val latency: Long = 0) : RankSaveIO<Row, Detail> {
        var log = listOf<RankScreen>(); var rev = 0; var lastOp = ""; var failNext = 0; var landThenFail = 0; var removed = 0
        val pushes = ArrayList<Pair<List<RankScreen>, List<RankScreen>>>()
        val ops = ArrayList<String>()
        var stored = RankPending()
        var release = CompletableDeferred<Unit>()
        override suspend fun push(rev: Int, count: Int, add: List<RankScreen>, drop: List<RankScreen>, changes: List<RankChange>, opId: String): Row {
            delay(latency)
            pushes += add to drop; ops += opId
            if (failNext > 0) { failNext--; throw IllegalStateException("offline") }
            if (lastOp == opId) return Row(this.rev, log.size)
            if (rev != this.rev || count != log.size) throw Conflict()
            val l = log.toMutableList()
            for (d in drop) {
                val i = l.indexOfFirst { RankSync.key(it) == RankSync.key(d) }
                if (i < 0) throw Conflict()
                l.removeAt(i); removed++
            }
            log = l + add; this.rev++; lastOp = opId
            if (landThenFail > 0) { landThenFail--; throw IllegalStateException("timeout") }
            return Row(this.rev, log.size)
        }
        override suspend fun reload(): Detail { delay(latency); return Detail(rev, log) }
        override fun isConflict(e: Throwable) = e is Conflict
        override fun revOf(r: Row) = r.rev
        override fun screensOf(r: Row) = r.screens
        override fun revOfDetail(d: Detail) = d.rev
        override fun logOf(d: Detail) = d.log
        override fun load() = stored
        override fun save(p: RankPending) { stored = p }
        override suspend fun wait(ms: Long) { release.await(); release = CompletableDeferred() }
        fun elsewhere(s: RankScreen) { log = log + s; rev++ }
    }

    private suspend fun idle(s: RankSaver<Row, Detail>) { repeat(1000) { if (!s.saving && !s.unsaved) return; delay(5) } }

    private fun saving(f: Fake, block: suspend CoroutineScope.(RankSaver<Row, Detail>) -> Unit) = runBlocking {
        val s = RankSaver(f, this)
        try { block(s) } finally { s.stop() }
    }

    @Test fun fastLockInsWithAConflictNeverLoseScreens() {
        val f = Fake(latency = 15)
        saving(f) { s ->
            val mine = ArrayList<RankScreen>()
            repeat(12) { i ->
                val x = screen("F"); mine += x; s.add(x)
                if (i == 5) f.elsewhere(screen("U"))
                delay(4)
            }
            idle(s)
            assertFalse(s.unsaved)
            assertEquals(f.log, s.log)
            assertEquals(mine, f.log.filter { it.s == "F" })
            assertEquals(1, f.log.count { it.s == "U" })
            assertEquals(0, f.removed)
        }
    }

    @Test fun aConflictNeverEmptiesTheLog() {
        val f = Fake(latency = 5)
        saving(f) { s ->
            repeat(6) { s.add(screen()) }
            idle(s)
            val six = f.log
            f.elsewhere(screen("U"))
            s.add(screen())
            assertTrue(s.log.size >= 7)
            idle(s)
            assertEquals(8, f.log.size)
            assertEquals(six, f.log.take(6))
            assertEquals(f.log, s.log)
        }
    }

    @Test fun undoAndRedoNameTheScreen() {
        val f = Fake()
        saving(f) { s ->
            val five = List(5) { screen() }
            five.forEach(s::add)
            idle(s)
            s.drop(listOf(five[4])); s.save()
            s.drop(listOf(five[0])); s.save()
            idle(s)
            assertEquals(five.subList(1, 4), f.log)
            assertEquals(listOf(five[4], five[0]).map(RankSync::key), f.pushes.flatMap { it.second }.map(RankSync::key))
            assertTrue(f.pushes.last().first.isEmpty())
        }
    }

    @Test fun noSignalKeepsItAndSavesLater() {
        val f = Fake()
        saving(f) { first ->
            first.add(screen()); idle(first)
            f.failNext = 1000
            val two = listOf(screen(), screen())
            two.forEach(first::add)
            delay(30)
            assertTrue(first.unsaved)
            assertTrue(first.error!!.contains("kept on this device"))
            assertEquals(two, f.stored.adds)
            first.stop()
            f.failNext = 0
            val again = RankSaver(f, this)  // the app is opened again
            assertEquals(2, again.waitingScreens)
            again.adopt(f.log, f.rev)
            idle(again)
            assertEquals(two, f.log.drop(1))
            assertTrue(f.stored.isEmpty)
        }
    }

    @Test fun aPushThatLandedIsNotAppliedTwice() {
        val f = Fake()
        saving(f) { s ->
            s.add(screen()); idle(s)
            f.landThenFail = 1
            s.add(screen())
            delay(20)
            assertTrue(s.unsaved)
            f.release.complete(Unit)
            idle(s)
            assertEquals(2, f.log.size)
            assertEquals(f.log, s.log)
            assertEquals(1, f.ops.drop(1).toSet().size)
        }
    }
}
