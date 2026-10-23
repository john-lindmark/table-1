package site.table1.events.library

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import kotlin.math.roundToLong

/*
 * Saving a cube ranking (contract/cube-rankings-2026-10-21.md, "Saving"; reference testdata/ranking-save/make_cases.py,
 * shared cases in testdata/ranking-save/cases.json, read by iOS RankSyncTests and web rankSync.test.ts too).
 * Twice on 2026-10-23 an iPhone wiped a 500-screen ranking: overlapping saves hit a conflict, the recovery cleared the
 * app's copy of the server's log, and a save still waiting worked out "keep 0, add 1" from it. Now nothing is worked out
 * by comparing logs: the app keeps the server's log as it last said it is, plus what was done here and not yet saved
 * (lock-ins and picks to add, undone or redone screens to drop), and everything shown and sent comes from plan().
 * Removals are only ever ones the person made.
 */
object RankSync {
    /** What makes two screens the same screen: session, cards in order and time in whole ms (the server's rule too). */
    fun key(s: RankScreen): String = "${s.s}|${s.o.joinToString(",").lowercase()}|${s.t?.roundToLong()?.toString() ?: ""}"

    data class Plan(val log: List<RankScreen>, val add: List<RankScreen>, val drop: List<RankScreen>, val keep: Int) {
        val removed get() = drop.size
    }

    fun plan(server: List<RankScreen>, adds: List<RankScreen>, drops: List<RankScreen>): Plan {
        val log = server.map { it to false }.toMutableList()
        val have = server.map(::key).toMutableSet()
        for (a in adds) if (have.add(key(a))) log += a to true
        val drop = ArrayList<RankScreen>()
        for (d in drops) {
            val k = key(d)
            val i = log.indexOfFirst { key(it.first) == k }
            if (i < 0) continue
            if (!log.removeAt(i).second) drop += d
        }
        return Plan(log.map { it.first }, log.filter { it.second }.map { it.first }, drop, server.size)
    }
}

/** What's waiting to be saved for one ranking, kept on the device so a crash, a force-quit or no signal loses nothing. */
@Serializable
data class RankPending(
    val adds: List<RankScreen> = emptyList(),
    val drops: List<RankScreen> = emptyList(),
    val changes: List<RankChange> = emptyList(),
    /** The push being sent: retried with the same op id, so one that landed isn't applied twice. */
    val op: Op? = null,
) {
    @Serializable
    data class Op(val id: String, val rev: Int, val count: Int, val adds: Int, val drops: Int, val changes: Int)

    val isEmpty get() = adds.isEmpty() && drops.isEmpty() && changes.isEmpty()

    /** After a save: what it sent is no longer waiting (anything done meanwhile stays, in order). */
    fun settle(op: Op) = RankPending(adds.drop(op.adds), drops.drop(op.drops), changes.drop(op.changes), null)
}

/** Pending work on disk, one file per ranking. */
class RankPendingFile(dir: File, id: String) {
    private val file = File(dir, "pending-${id.lowercase()}.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): RankPending = runCatching { json.decodeFromString<RankPending>(file.readText()) }.getOrDefault(RankPending())

    fun save(p: RankPending) {
        runCatching {
            if (p.isEmpty) { file.delete(); return }
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(json.encodeToString(p))
            tmp.renameTo(file)
        }
    }
}

/** A push answered with a log of the wrong length: read the log again. */
class RankMismatch : Exception("The saved ranking didn't match")

/** How a ranking reaches the server; tests use a fake. */
interface RankSaveIO<R, D> {
    /** cube_ranking_push with p_keep = p_count = count, p_removed = drop.size. */
    suspend fun push(rev: Int, count: Int, add: List<RankScreen>, drop: List<RankScreen>, changes: List<RankChange>, opId: String): R
    /** cube_ranking_get, after a conflict. */
    suspend fun reload(): D
    fun isConflict(e: Throwable): Boolean
    fun revOf(r: R): Int
    fun screensOf(r: R): Int
    fun revOfDetail(d: D): Int
    fun logOf(d: D): List<RankScreen>
    fun load(): RankPending
    fun save(p: RankPending)
    /** Waits before a retry. */
    suspend fun wait(ms: Long) = delay(ms)
}

/**
 * One ranking's saving: the server's log, what's waiting, and one push at a time until nothing is. Each push names exactly
 * what it adds and takes out against the log the server last sent; the server refuses it unless its log is that log, so a
 * stale push can only cause a reload, never a loss. After a conflict the log is read again and what's waiting goes on top
 * of it: nothing done here is thrown away. With no signal it's kept and tried again (2 s, 5 s, 15 s, 30 s, then a minute).
 */
class RankSaver<R, D>(private val io: RankSaveIO<R, D>, private val scope: CoroutineScope) {
    var server: List<RankScreen> = emptyList(); private set
    var rev = 0; private set
    var pending: RankPending = io.load(); private set
    var saving = false; private set
    var failures = 0; private set
    var error: String? = null; private set
    private var retry: Job? = null

    var onSaved: (R) -> Unit = {}
    var onReloaded: (D, Boolean) -> Unit = { _, _ -> }
    var onChange: () -> Unit = {}

    val log get() = RankSync.plan(server, pending.adds, pending.drops).log
    val unsaved get() = !pending.isEmpty
    val waitingScreens get() = pending.adds.size + pending.drops.size

    /** The server's log, read (not while a push is out: that push reloads if it has to). */
    fun adopt(log: List<RankScreen>, rev: Int) {
        if (saving) return
        server = log; this.rev = rev
        if (unsaved) save()
    }

    fun add(s: RankScreen) { pending = pending.copy(adds = pending.adds + s); save() }
    fun drop(ss: List<RankScreen>) { pending = pending.copy(drops = pending.drops + ss) }
    fun changes(rows: List<RankChange>) { pending = pending.copy(changes = pending.changes + rows); io.save(pending) }

    fun save() {
        io.save(pending)
        if (saving || !unsaved) return
        saving = true
        retry?.cancel(); retry = null
        scope.launch {
            try { flush() } finally { saving = false; onChange() }
        }
    }

    private suspend fun flush() {
        var conflicts = 0
        while (unsaved) {
            val p = RankSync.plan(server, pending.adds, pending.drops)
            val o = pending.op
            val op = if (o != null && o.rev == rev && o.count == server.size && o.adds == pending.adds.size && o.drops == pending.drops.size &&
                o.changes == pending.changes.size) o
            else RankPending.Op(UUID.randomUUID().toString().lowercase(), rev, server.size, pending.adds.size, pending.drops.size, pending.changes.size)
            pending = pending.copy(op = op)
            io.save(pending)
            try {
                val r = io.push(rev, p.keep, p.add, p.drop, pending.changes.take(op.changes), op.id)
                if (io.screensOf(r) != p.log.size) throw RankMismatch()
                server = p.log; rev = io.revOf(r)
                pending = pending.settle(op)
                io.save(pending)
                failures = 0; error = null
                onSaved(r)
            } catch (e: Throwable) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                if (io.isConflict(e) || e is RankMismatch) {
                    conflicts++
                    pending = pending.copy(op = null)
                    val d = if (conflicts <= 5) runCatching { io.reload() }.getOrNull() else null
                    if (d == null) {
                        error = "Couldn't save just now. What you've done is kept on this device and saved when Table 1 can."
                        later(); return
                    }
                    val theirs = io.logOf(d) != server
                    server = io.logOf(d); rev = io.revOfDetail(d)
                    onReloaded(d, theirs)
                } else {
                    error = "Not saved yet: ${e.message}. It's kept on this device and saved when Table 1 can."
                    later(); return
                }
            }
            onChange()
        }
    }

    private fun later() {
        failures++
        val ms = RETRY_MS[minOf(failures, RETRY_MS.size) - 1]
        retry = scope.launch { io.wait(ms); retry = null; save() }
    }

    fun stop() { retry?.cancel(); retry = null }

    companion object {
        val RETRY_MS = listOf(2_000L, 5_000L, 15_000L, 30_000L, 60_000L)
    }
}
