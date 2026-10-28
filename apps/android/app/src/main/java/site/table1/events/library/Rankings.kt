package site.table1.events.library

import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.postgrest
import io.ktor.client.plugins.timeout
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import site.table1.events.T1App
import site.table1.events.util.Telemetry
import java.io.File
import java.util.UUID

// Cube rankings (contract/cube-rankings-2026-10-21.md): stack-rank a cube's cards, cuberanker.com style, refined with
// P1P1 picks. The server keeps each ranking's screen log and change log; everything shown is worked out here from the
// log (CubeRanking.kt). One RankingModel per open ranking is shared by its screens: it holds the log, saves one push at
// a time, and re-reads someone else's ranking while it's open so it can be watched live. Same as iOS Rankings.swift.

@Serializable
data class RankingCube(val id: String, val name: String, val mine: Boolean = false, val owner: Person? = null,
                       @SerialName("can_see") val canSee: Boolean? = null, val cards: List<String>? = null,
                       /** cube_ranking_get only: Oracle id → the printing the cube holds, so cards show as they are in the cube. */
                       val printings: Map<String, String>? = null)

/** A ranking is titled by who ranked it (contract/cube-rankings-2026-10-21.md § Names, testdata/ranking-names). Blank and
 *  "My ranking", what every ranking was called before 2026-10-28 and what the server still stores for no name, aren't names. */
object RankingName {
    const val UNNAMED = "My ranking"

    fun label(name: String): String? = name.trim().takeUnless { it.isEmpty() || it.equals(UNNAMED, ignoreCase = true) }

    fun title(name: String, by: String?, mine: Boolean): String =
        listOfNotNull(by?.trim()?.ifEmpty { null } ?: if (mine) "You" else "Someone", label(name)).joinToString(" · ")
}

@Serializable
data class RankingRow(
    val id: String, @SerialName("list_id") val listId: String, val name: String, val depth: String, val top: Int, val sharing: String,
    val screens: Int, val rev: Int, val sorted: Int, val categories: Int, val ranked: Int,
    @SerialName("updated_at") val updatedAt: String? = null, val mine: Boolean, val by: Person? = null, val cube: RankingCube? = null,
) {
    /** Who ranked it, then the name they gave it if any: "Mara", "Mara · Power only". */
    val title get() = RankingName.title(name, by?.displayName, mine)
    /** The name its maker gave it; null for the default. */
    val label get() = RankingName.label(name)
    val progress get() = "$sorted/$categories sorted · $ranked/$top ranked"
}

/** ranking-brief: Claude's 2-5 sentence comparison of two rankings for one list, or why there isn't one yet. */
@Serializable
data class RankingBrief(val brief: String? = null, val reason: String? = null, val cached: Boolean? = null, val error: String? = null)

/** rankable_cubes: someone else's cube you can rank, with how many rankings of it you can see and how many are yours. */
@Serializable
data class RankableCube(val id: String, val name: String, val owner: Person? = null, val cards: Int = 0, val rankings: Int = 0, val mine: Int = 0)

@Serializable
data class CubeRankings(val cube: RankingCube? = null, @SerialName("can_rank") val canRank: Boolean = false, val rankings: List<RankingRow> = emptyList())

@Serializable
data class RankingDetail(
    val id: String, @SerialName("list_id") val listId: String, val name: String, val depth: String, val top: Int, val sharing: String,
    val screens: Int, val rev: Int, val sorted: Int, val categories: Int, val ranked: Int,
    @SerialName("updated_at") val updatedAt: String? = null, val mine: Boolean, val by: Person? = null,
    val log: List<RankScreen> = emptyList(), val changes: List<RankChange> = emptyList(), val cube: RankingCube? = null,
    /** The cube's cards when the ranking last caught up: cards added since wait outside its lists until placed. */
    val baseline: List<String>? = null,
) {
    val row get() = RankingRow(id, listId, name, depth, top, sharing, screens, rev, sorted, categories, ranked, updatedAt, mine, by)
}

/** A card as the ranking screens show it. */
data class RankCard(val oracleId: String, val name: String, val printing: CatalogPrinting?)

object RankingsStore {
    private val models = HashMap<String, RankingModel>()
    fun model(id: String): RankingModel = models.getOrPut(id) { RankingModel(id) }
    fun stop() = models.clear()

    suspend fun rankings(listId: String?): CubeRankings =
        T1App.supabase.postgrest.rpc("cube_rankings", buildJsonObject { if (listId != null) put("p_list_id", listId) else put("p_list_id", JsonNull) })
            .decodeAs<CubeRankings>()

    /** Briefs already fetched this session, by "a|b|list". */
    private val briefs = HashMap<String, RankingBrief>()

    /** The brief comparing ranking [a] with [b] on one list (written once per change on the server, then kept). */
    suspend fun brief(a: String, b: String, list: RankJob): RankingBrief {
        val key = "$a|$b|${list.key}"
        briefs[key]?.let { return it }
        val r = try {
            val response = T1App.supabase.functions.invoke("ranking-brief") {
                contentType(ContentType.Application.Json)
                setBody(buildJsonObject { put("a", a); put("b", b); put("list", list.key) }.toString())
                timeout { requestTimeoutMillis = 90_000 }
            }
            T1App.json.decodeFromString<RankingBrief>(response.bodyAsText())
        } catch (e: Exception) {
            val msg = e.message?.let { m -> Regex("\"error\"\\s*:\\s*\"([^\"]+)\"").find(m)?.groupValues?.get(1) }
            throw IllegalStateException(msg ?: "The brief couldn't be written just now.")
        }
        if (r.brief != null || r.reason != null) briefs[key] = r
        Telemetry.capture(if (r.brief != null) "ranking_brief_shown" else "ranking_brief_missing", mapOf("list" to list.key, "cached" to (r.cached ?: false)))
        return r
    }

    /** Other people's cubes you can see and rank (friends' and people you've played with). */
    suspend fun rankable(): List<RankableCube> = T1App.supabase.postgrest.rpc("rankable_cubes").decodeAs<List<RankableCube>>()

    suspend fun get(id: String): RankingDetail =
        T1App.supabase.postgrest.rpc("cube_ranking_get", buildJsonObject { put("p_id", id) }).decodeAs<RankingDetail>()

    @Serializable private data class CaughtUp(val baseline: List<String>)

    /** The ranking takes its cube as it is now as the cards it has caught up with; returns them. */
    suspend fun catchUp(id: String): List<String> =
        T1App.supabase.postgrest.rpc("cube_ranking_catch_up", buildJsonObject { put("p_id", id) }).decodeAs<CaughtUp>().baseline

    suspend fun create(listId: String, name: String, depth: String, top: Int, sharing: String, ownCube: Boolean): RankingRow {
        val row = T1App.supabase.postgrest.rpc("cube_ranking_create", buildJsonObject {
            put("p_id", UUID.randomUUID().toString().lowercase()); put("p_list_id", listId); put("p_name", name)
            put("p_depth", depth); put("p_top", top); put("p_sharing", sharing)
        }).decodeAs<RankingRow>()
        Telemetry.capture("ranking_created", mapOf("depth" to depth, "top" to top, "sharing" to sharing, "own_cube" to ownCube))
        return row
    }

    suspend fun update(id: String, name: String? = null, depth: String? = null, top: Int? = null, sharing: String? = null): RankingRow =
        T1App.supabase.postgrest.rpc("cube_ranking_update", buildJsonObject {
            put("p_id", id)
            if (name != null) put("p_name", name) else put("p_name", JsonNull)
            if (depth != null) put("p_depth", depth) else put("p_depth", JsonNull)
            if (top != null) put("p_top", top) else put("p_top", JsonNull)
            if (sharing != null) put("p_sharing", sharing) else put("p_sharing", JsonNull)
        }).decodeAs<RankingRow>()

    /** cube_ranking_push the safe way: the whole log as last read is kept (p_keep = p_count), `drop` names the screens to
     *  take out, `add` the ones to append (contract § Saving). */
    suspend fun push(id: String, rev: Int, count: Int, add: List<RankScreen>, drop: List<RankScreen>, progress: RankingState.Progress,
                     changes: List<RankChange>, opId: String): RankingRow =
        T1App.supabase.postgrest.rpc("cube_ranking_push", buildJsonObject {
            put("p_id", id); put("p_rev", rev); put("p_keep", count); put("p_count", count); put("p_removed", drop.size)
            fun screens(name: String, list: List<RankScreen>) = putJsonArray(name) {
                for (s in list) add(buildJsonObject {
                    put("s", s.s); putJsonArray("o") { s.o.forEach { add(JsonPrimitive(it)) } }; s.t?.let { put("t", it) }
                })
            }
            screens("p_add", add); screens("p_drop", drop)
            put("p_sorted", progress.sorted); put("p_categories", progress.categories); put("p_ranked", progress.ranked); put("p_op_id", opId)
            putJsonArray("p_changes") {
                for (c in changes) add(buildJsonObject {
                    put("s", c.s); put("c", c.c)
                    if (c.f != null) put("f", c.f) else put("f", JsonNull)
                    if (c.to != null) put("to", c.to) else put("to", JsonNull)
                    c.t?.let { put("t", it) }; c.by?.let { put("by", it) }; c.n?.let { put("n", it) }
                })
            }
        }).decodeAs<RankingRow>()

    /** A push the server refused because its log isn't the one this device last read (PT409; 40001 from before the fix). */
    fun isConflict(e: Throwable) = e.message?.contains("changed on another device") == true || e.message?.contains("PT409") == true

    suspend fun delete(id: String) {
        T1App.supabase.postgrest.rpc("cube_ranking_delete", buildJsonObject { put("p_id", id) })
        models.remove(id)
        Telemetry.capture("ranking_deleted")
    }
}

/** One open ranking: its log, its cards and what's worked out from them. Screens collect [version]. */
class RankingModel(val id: String) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version.asStateFlow()
    private fun bump() { _version.value++ }

    var row: RankingRow? = null; private set
    var cube: RankingCube? = null; private set
    var log: List<RankScreen> = emptyList(); private set
    var changes: List<RankChange> = emptyList(); private set
    var state: RankingState? = null; private set
    var cards: Map<String, RankCard> = emptyMap(); private set
    var reask: Pair<RankJob, List<String>>? = null; private set
    var error: String? = null
    var notice: String? = null
    var cubeGone = false; private set
    /** The cube's cards the ranking last caught up with. */
    var baseline: List<String>? = null; private set

    /** The server's log and what's waiting to be saved (RankSync.kt): `log` is always its plan. */
    private val saver = RankSaver(object : RankSaveIO<RankingRow, RankingDetail> {
        override suspend fun push(rev: Int, count: Int, add: List<RankScreen>, drop: List<RankScreen>, changes: List<RankChange>, opId: String) =
            RankingsStore.push(id, rev, count, add, drop, state?.progress ?: RankingState.Progress(0, 0, 0), changes, opId)
        override suspend fun reload() = RankingsStore.get(id)
        override fun isConflict(e: Throwable) = RankingsStore.isConflict(e)
        override fun revOf(r: RankingRow) = r.rev
        override fun screensOf(r: RankingRow) = r.screens
        override fun revOfDetail(d: RankingDetail) = d.row.rev
        override fun logOf(d: RankingDetail) = d.log
        private val file = RankPendingFile(File(T1App.instance.filesDir, "rankings"), id)
        override fun load() = file.load()
        override fun save(p: RankPending) = file.save(p)
    }, scope).also { s ->
        s.onSaved = { r -> row = r; lastChange = System.currentTimeMillis(); error = null; relog() }
        s.onReloaded = { d, theirs ->
            Telemetry.capture("ranking_save_conflict", mapOf("waiting" to s.waitingScreens))
            row = d.row; cube = d.cube; baseline = d.baseline; changes = d.changes + s.pending.changes; log = s.log
            scope.launch { rebuild(d.cube?.cards); bump() }
            if (theirs) notice = "This ranking changed on another device. Your screens were added on top of it."
        }
        s.onChange = {
            s.error?.let { error = it; Telemetry.capture("ranking_save_failed", mapOf("waiting" to s.waitingScreens)) }
            if (!s.unsaved && !s.saving) maybeCatchUp()
            bump()
        }
        if (s.unsaved) Telemetry.capture("ranking_save_restored", mapOf("screens" to s.waitingScreens))
    }
    private var lastChange = System.currentTimeMillis()

    val mine get() = row?.mine ?: false
    /** Something done here isn't saved yet (it's kept on the device and sent until it is). */
    val unsaved get() = saver.unsaved
    val unsavedScreens get() = saver.waitingScreens

    /** The log to show is the server's plus what's waiting; the state is rebuilt only if that differs. */
    private fun relog() {
        val next = saver.log
        if (next == log) return
        log = next
        rebuildState()
    }
    fun card(id: String) = cards[id.lowercase()]
    fun cardAt(x: Int) = state?.let { cards[it.id(x)] }

    suspend fun load() {
        runCatching { RankingsStore.get(id) }.onSuccess { adopt(it); error = null }.onFailure { error = it.message }
        bump()
    }

    private suspend fun adopt(d: RankingDetail) {
        val same = d.log == saver.server
        val cubeMoved = d.cube?.cards != cube?.cards || d.baseline != baseline
        val changed = !same || cubeMoved || row?.depth != d.depth || row?.top != d.top || state == null
        row = d.row; cube = d.cube; baseline = d.baseline
        if (changed) lastChange = System.currentTimeMillis()
        if (saver.saving) return  // the save in flight reloads if it has to
        val shown = log
        saver.adopt(d.log, d.row.rev)
        log = saver.log
        changes = d.changes + saver.pending.changes
        if (changed || log != shown || cards.isEmpty()) rebuild(d.cube?.cards)
    }

    /** Resolves the cube's cards against the catalog and works out the state. Cards that left the cube (in the log or
     *  the baseline) are looked up too, for their names; only the cube's cards make the lists. */
    private suspend fun rebuild(cubeCards: List<String>?) {
        val r = row ?: return
        cubeGone = cubeCards == null
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return
        val ids = (cubeCards ?: state?.category?.keys?.toList() ?: log.flatMap { it.o }.distinct()).map { it.lowercase() }
        val inCube = ids.toSet()
        val wanted = (ids + log.flatMap { it.o } + baseline.orEmpty()).map { it.lowercase() }.distinct()
        val resolved = withContext(Dispatchers.Default) {
            val oracles = db.oraclesById(wanted)
            val covers = db.covers(oracles.values.map { it.idx })
            val held = cube?.printings.orEmpty()
            val found = if (held.isEmpty()) emptyMap() else db.printings(held.values.toSet())
            oracles.mapNotNull { (id, o) ->
                RankJob.ofColor(GroupKeys.of(o)[CardGrouping.Color])?.let { id to (RankCard(id, o.name, covers[o.idx]) to it) }
            }.toMap().mapValues { (_, v) -> asInCube(v.first, held, found) to v.second }
        }
        cards = resolved.mapValues { it.value.first }
        val l = log
        val fresh = cubeChange.added.toSet()
        val jobs = resolved.filterKeys { it in inCube }.mapValues { it.value.second }
        state = withContext(Dispatchers.Default) { RankingState(id, jobs, l, r.depth, r.top, fresh) }
        maybeCatchUp()
    }

    /** Cards added to the cube since this ranking caught up, and cards removed. */
    val cubeChange: CubeChange get() = if (cubeGone) CubeChange.of(null, null) else CubeChange.of(cube?.cards, baseline)

    /** Where a re-rank starts: the first list with new cards to place (colors, then the final). */
    val reRankJob: RankJob? get() = state?.let { st -> (st.jobs + RankJob.Final).firstOrNull { st.session(it).waiting.isNotEmpty() } }

    private var catching = false
    /** Your ranking has caught up with its cube once every new card is placed: then the change is no longer news. */
    private fun maybeCatchUp() {
        val st = state ?: return
        if (!mine || catching || unsaved || saver.saving || cubeChange.added.isEmpty() || st.waiting.isNotEmpty()) return
        catchUp()
    }

    /** Takes the cube as it is now as the cards this ranking has caught up with (after placing new cards, or to dismiss
     *  removals). */
    fun catchUp() {
        if (!mine || catching) return
        catching = true
        scope.launch {
            runCatching { RankingsStore.catchUp(id) }
                .onSuccess { baseline = it; rebuild(cube?.cards); Telemetry.capture("ranking_caught_up") }
                .onFailure { error = it.message }
            catching = false
            bump()
        }
    }

    companion object {
        /** A card in the printing the cube holds; one the card data doesn't have keeps its usual art. */
        fun asInCube(c: RankCard, printings: Map<String, String>, found: Map<String, CatalogPrinting>): RankCard =
            printings[c.oracleId]?.let { found[it] }?.let { c.copy(printing = it) } ?: c
    }

    private fun rebuildState() {
        val st = state ?: return; val r = row ?: return
        state = RankingState(id, st.category, log, r.depth, r.top, st.fresh)
    }

    data class Question(val session: RankSession, val cards: List<Int>, val pinned: List<Int>)

    /** The next screen of a job: a redone screen's cards first while their order is open. */
    fun question(job: RankJob): Question? {
        val st = state ?: return null
        val s = st.session(job)
        val q = s.question ?: return Question(s, emptyList(), emptyList())
        val r = reask
        if (r != null && r.first == job && CubeRanking.reaskOpen(st.knowledge, s, r.second)) return Question(s, st.knowledge.indexes(r.second), emptyList())
        return Question(s, q, s.pinned)
    }

    private fun now() = System.currentTimeMillis().toDouble()

    private fun record(before: RankingState?, after: RankingState?, by: String, screen: Int?, only: List<RankJob>? = null) {
        if (before == null || after == null) return
        val t = now()
        val rows = RankChange.diff(before.places(only), after.places(only)).map { it.copy(t = t, by = by, n = screen) }
        changes = changes + rows
        saver.changes(rows)
    }

    /** Locks a screen in (yours only) and saves it. A tap meant for a screen that's already gone (a double tap) is ignored. */
    fun lockIn(job: RankJob, order: List<Int>) {
        val st = state ?: return
        if (!mine) return
        val q = question(job)
        if (q == null || order.size < 2 || order.size != q.cards.size || order.toSet() != q.cards.toSet()) {
            Telemetry.capture("ranking_lockin_stale")
            return
        }
        val screen = RankScreen(job.key, order.map(st::id), now())
        val wasDone = st.session(job).done
        log = log + screen
        reask = null
        val next = st.appending(screen)
        state = next
        record(st, next, "screen", log.size, if (job == RankJob.Final) null else listOf(job, RankJob.Final))
        if (!wasDone && next.session(job).done) Telemetry.capture("ranking_job_done", mapOf("job" to job.key, "screens" to (next.knowledge.perJob[job.key] ?: 0)))
        saver.add(screen)
        bump()
    }

    fun undo(job: RankJob) {
        if (!mine) return
        val i = log.indexOfLast { it.s == job.key }
        if (i < 0) return
        val removed = log[i]
        log = log.filterIndexed { k, _ -> k != i }
        saver.drop(listOf(removed))
        reask = job to removed.o
        Telemetry.capture("ranking_undo")
        val before = state
        rebuildState()
        record(before, state, "undo", i + 1)
        saver.save()
        bump()
    }

    fun redo(i: Int) {
        if (!mine || i !in log.indices) return
        val removed = log[i]
        log = log.filterIndexed { k, _ -> k != i }
        saver.drop(listOf(removed))
        reask = if (removed.s == RankJob.Pick.key) null else removed.job?.let { it to removed.o }
        Telemetry.capture("ranking_redo")
        val before = state
        rebuildState()
        record(before, state, "redo", i + 1)
        saver.save()
        bump()
    }

    fun redoChangesNothing(i: Int): Boolean {
        val st = state ?: return false
        if (i !in log.indices) return false
        return RankKnowledge.of(st.knowledge.ids, log.filterIndexed { k, _ -> k != i }).same(st.knowledge)
    }

    // P1P1
    val pack: List<String> get() = state?.let { CubeRanking.pack(id, it.knowledge) } ?: emptyList()
    fun disagreements(picked: String, pack: List<String>) = state?.let { CubeRanking.disagreements(it.knowledge, picked, pack) } ?: emptyList()
    fun newOrders(picked: String, pack: List<String>): Int {
        val K = state?.knowledge ?: return 0
        val p = K.indexOf(picked) ?: return 0
        return pack.mapNotNull { K.indexOf(it) }.count { it != p && !K.known(p, it) && !K.known(it, p) }
    }
    fun pickWinRemovals(picked: String, pack: List<String>) = state?.let { CubeRanking.pickWins(it.knowledge.ids, log, picked, pack) } ?: emptyList()

    fun pick(picked: String, pack: List<String>, wins: Boolean) {
        val st = state ?: return; val r = row ?: return
        if (!mine) return
        if (pack != this.pack || picked !in pack) {
            Telemetry.capture("ranking_lockin_stale", mapOf("pick" to true))
            return
        }
        val disagreed = disagreements(picked, pack).size
        val removed = if (wins) pickWinRemovals(picked, pack) else emptyList()
        val screen = RankScreen(RankJob.Pick.key, listOf(picked) + pack.filter { it != picked }, now())
        saver.drop(removed.map { log[it] })
        log = log.filterIndexed { k, _ -> k !in removed } + screen
        reask = null
        val next = if (removed.isEmpty()) st.appending(screen) else RankingState(id, st.category, log, r.depth, r.top, st.fresh)
        state = next
        record(st, next, if (removed.isEmpty()) "pick" else "pick_win", log.size)
        Telemetry.capture("ranking_pick", mapOf("disagreed" to disagreed, "resolution" to (if (disagreed == 0) "none" else if (wins) "pick_wins" else "keep"),
            "removed" to removed.size))
        saver.add(screen)
        bump()
    }

    data class Pick(val index: Int, val screen: RankScreen, val disagreed: Int, val won: Boolean)

    /** Every pick so far, newest first: how many of its orders disagreed and were kept out, and whether it won. */
    val picks: List<Pick>
        get() {
            val K = state?.knowledge ?: return emptyList()
            val won = changes.filter { it.by == "pick_win" }.mapNotNull { it.n }.toSet()
            return log.withIndex().filter { it.value.s == RankJob.Pick.key }
                .map { Pick(it.index, it.value, K.contradicted[it.index]?.size ?: 0, (it.index + 1) in won) }.reversed()
        }

    fun update(name: String? = null, depth: String? = null, top: Int? = null, sharing: String? = null) {
        scope.launch {
            val before = state
            runCatching { RankingsStore.update(id, name, depth, top, sharing) }
                .onSuccess {
                    row = it
                    rebuildState()
                    if (depth != null || top != null) { record(before, state, "settings", null); saver.save() }
                    error = null
                }
                .onFailure { error = it.message }
            bump()
        }
    }

    /** Watching: someone else's ranking every 10 s (60 s once nothing changed for a minute); yours every 60 s. */
    suspend fun watch() {
        while (kotlin.coroutines.coroutineContext.isActive) {
            val quiet = System.currentTimeMillis() - lastChange > 60_000
            delay(if (mine || quiet) 60_000 else 10_000)
            if (saver.saving) continue
            if (unsaved) saver.save() else runCatching { RankingsStore.get(id) }.onSuccess { adopt(it); bump() }
        }
    }

    data class JobList(val placed: List<RankCard>, val waiting: List<RankCard>, val waitingTitle: String?, val rest: List<RankCard>,
                       val restTitle: String?, val session: RankSession)

    /** A job's list: the placed cards, best first, then the cube's new cards waiting to be placed, then the rest by name.
     *  Only the cube's cards: one that left it is in no list. */
    fun list(job: RankJob): JobList? {
        val st = state ?: return null
        val s = st.session(job)
        val placed = s.top.mapNotNull(::cardAt)
        val skip = (s.top + s.waiting).toSet()
        val waiting = s.waiting.mapNotNull(::cardAt).sortedBy { it.name.lowercase() }
        val rest = st.scope(job).members.filter { it !in skip }.mapNotNull(::cardAt).sortedBy { it.name.lowercase() }
        val title = when {
            rest.isEmpty() -> null
            s.top.size >= s.target -> "Below the top ${s.target}, in no particular order · ${rest.size}"
            else -> "Not placed yet · ${rest.size}"
        }
        return JobList(placed, waiting, if (waiting.isEmpty()) null else "New in the cube, not placed yet · ${waiting.size}", rest, title, s)
    }

    fun listText(job: RankJob): String {
        val l = list(job) ?: return ""
        val lines = l.placed.mapIndexed { i, c -> "${i + 1}. ${c.name}" }.toMutableList()
        if (l.waitingTitle != null) { lines += ""; lines += l.waitingTitle; lines += l.waiting.map { it.name } }
        if (l.restTitle != null && l.rest.isNotEmpty()) { lines += ""; lines += l.restTitle; lines += l.rest.map { it.name } }
        return lines.joinToString("\n") + "\n"
    }
}

/** What changed in a cube since a ranking last caught up: cards added (they wait to be placed) and removed (gone from its
 *  lists). Empty without a baseline or the cube's cards. */
data class CubeChange(val added: List<String> = emptyList(), val removed: List<String> = emptyList()) {
    val isEmpty get() = added.isEmpty() && removed.isEmpty()

    companion object {
        fun of(cubeCards: List<String>?, baseline: List<String>?): CubeChange {
            if (cubeCards == null || baseline == null) return CubeChange()
            val now = cubeCards.map { it.lowercase() }.toSet(); val then = baseline.map { it.lowercase() }.toSet()
            return CubeChange((now - then).sorted(), (then - now).sorted())
        }
    }
}
