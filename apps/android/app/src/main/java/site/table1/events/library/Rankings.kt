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
import java.util.UUID

// Cube rankings (contract/cube-rankings-2026-10-21.md): stack-rank a cube's cards, cuberanker.com style, refined with
// P1P1 picks. The server keeps each ranking's screen log and change log; everything shown is worked out here from the
// log (CubeRanking.kt). One RankingModel per open ranking is shared by its screens: it holds the log, saves one push at
// a time, and re-reads someone else's ranking while it's open so it can be watched live. Same as iOS Rankings.swift.

@Serializable
data class RankingCube(val id: String, val name: String, val mine: Boolean = false, val owner: Person? = null,
                       @SerialName("can_see") val canSee: Boolean? = null, val cards: List<String>? = null)

@Serializable
data class RankingRow(
    val id: String, @SerialName("list_id") val listId: String, val name: String, val depth: String, val top: Int, val sharing: String,
    val screens: Int, val rev: Int, val sorted: Int, val categories: Int, val ranked: Int,
    @SerialName("updated_at") val updatedAt: String? = null, val mine: Boolean, val by: Person? = null, val cube: RankingCube? = null,
) {
    val whose get() = if (mine) "Your ranking" else "${by?.displayName ?: "Someone"}'s ranking"
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

    suspend fun push(id: String, rev: Int, keep: Int, add: List<RankScreen>, progress: RankingState.Progress, changes: List<RankChange>, opId: String): RankingRow =
        T1App.supabase.postgrest.rpc("cube_ranking_push", buildJsonObject {
            put("p_id", id); put("p_rev", rev); put("p_keep", keep)
            putJsonArray("p_add") {
                for (s in add) add(buildJsonObject {
                    put("s", s.s); putJsonArray("o") { s.o.forEach { add(JsonPrimitive(it)) } }; s.t?.let { put("t", it) }
                })
            }
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

    private var serverLog: List<RankScreen> = emptyList()
    private var pending = ArrayList<RankChange>()
    private var saving = false
    private var force = false
    private var op: Triple<Int, Int, String>? = null
    private var lastChange = System.currentTimeMillis()

    val mine get() = row?.mine ?: false
    val unsaved get() = log != serverLog
    fun card(id: String) = cards[id.lowercase()]
    fun cardAt(x: Int) = state?.let { cards[it.id(x)] }

    suspend fun load() {
        runCatching { RankingsStore.get(id) }.onSuccess { adopt(it); error = null }.onFailure { error = it.message }
        bump()
    }

    private suspend fun adopt(d: RankingDetail) {
        val same = d.log == serverLog
        val changed = !same || row?.depth != d.depth || row?.top != d.top || state == null
        row = d.row; cube = d.cube
        if (changed) lastChange = System.currentTimeMillis()
        if (saving || (unsaved && same)) return
        serverLog = d.log; log = d.log; changes = d.changes; pending.clear()
        if (changed || cards.isEmpty()) rebuild(d.cube?.cards)
    }

    private suspend fun rebuild(cubeCards: List<String>?) {
        val r = row ?: return
        cubeGone = cubeCards == null
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return
        val ids = cubeCards ?: cards.keys.toList().ifEmpty { log.flatMap { it.o }.distinct() }
        val resolved = withContext(Dispatchers.Default) {
            val oracles = db.oraclesById(ids)
            val covers = db.covers(oracles.values.map { it.idx })
            oracles.mapNotNull { (id, o) ->
                RankJob.ofColor(GroupKeys.of(o)[CardGrouping.Color])?.let { id to (RankCard(id, o.name, covers[o.idx]) to it) }
            }.toMap()
        }
        cards = resolved.mapValues { it.value.first }
        val l = log
        state = withContext(Dispatchers.Default) { RankingState(id, resolved.mapValues { it.value.second }, l, r.depth, r.top) }
    }

    private fun rebuildState() {
        val st = state ?: return; val r = row ?: return
        state = RankingState(id, st.category, log, r.depth, r.top)
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
        pending += rows
    }

    fun lockIn(job: RankJob, order: List<Int>) {
        val st = state ?: return
        if (!mine) return
        val screen = RankScreen(job.key, order.map(st::id), now())
        val wasDone = st.session(job).done
        log = log + screen
        reask = null
        val next = st.appending(screen)
        state = next
        record(st, next, "screen", log.size, if (job == RankJob.Final) null else listOf(job, RankJob.Final))
        if (!wasDone && next.session(job).done) Telemetry.capture("ranking_job_done", mapOf("job" to job.key, "screens" to (next.knowledge.perJob[job.key] ?: 0)))
        bump(); save()
    }

    fun undo(job: RankJob) {
        if (!mine) return
        val i = log.indexOfLast { it.s == job.key }
        if (i < 0) return
        val removed = log[i]
        log = log.filterIndexed { k, _ -> k != i }
        reask = job to removed.o
        Telemetry.capture("ranking_undo")
        val before = state
        rebuildState()
        record(before, state, "undo", i + 1)
        bump(); save()
    }

    fun redo(i: Int) {
        if (!mine || i !in log.indices) return
        val removed = log[i]
        log = log.filterIndexed { k, _ -> k != i }
        reask = if (removed.s == RankJob.Pick.key) null else removed.job?.let { it to removed.o }
        Telemetry.capture("ranking_redo")
        val before = state
        rebuildState()
        record(before, state, "redo", i + 1)
        bump(); save()
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
        val disagreed = disagreements(picked, pack).size
        val removed = if (wins) pickWinRemovals(picked, pack) else emptyList()
        val screen = RankScreen(RankJob.Pick.key, listOf(picked) + pack.filter { it != picked }, now())
        log = log.filterIndexed { k, _ -> k !in removed } + screen
        reask = null
        val next = if (removed.isEmpty()) st.appending(screen) else RankingState(id, st.category, log, r.depth, r.top)
        state = next
        record(st, next, if (removed.isEmpty()) "pick" else "pick_win", log.size)
        Telemetry.capture("ranking_pick", mapOf("disagreed" to disagreed, "resolution" to (if (disagreed == 0) "none" else if (wins) "pick_wins" else "keep"),
            "removed" to removed.size))
        bump(); save()
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
                    if (depth != null || top != null) { record(before, state, "settings", null); force = true; save() }
                    error = null
                }
                .onFailure { error = it.message }
            bump()
        }
    }

    /** One push at a time: keep what the server and this device agree on, send the rest. */
    private fun save() {
        val r = row ?: return
        if (saving || (!unsaved && !force)) return
        force = false
        saving = true
        val local = log
        var keep = 0
        while (keep < minOf(local.size, serverLog.size) && local[keep] == serverLog[keep]) keep++
        val add = local.drop(keep)
        val opId = op?.takeIf { it.first == keep && it.second == local.size }?.third ?: UUID.randomUUID().toString().lowercase()
        op = Triple(keep, local.size, opId)
        val progress = state?.progress ?: RankingState.Progress(0, 0, 0)
        val sending = pending.toList()
        scope.launch {
            runCatching { RankingsStore.push(id, r.rev, keep, add, progress, sending, opId) }
                .onSuccess {
                    row = it; serverLog = local
                    repeat(minOf(sending.size, pending.size)) { pending.removeAt(0) }
                    op = null; error = null; lastChange = System.currentTimeMillis()
                    saving = false
                    if (unsaved) save()
                }
                .onFailure { e ->
                    saving = false
                    if (e.message?.contains("changed on another device") == true) {
                        op = null; pending.clear(); serverLog = emptyList()
                        notice = "This ranking changed on another device, so it has been reloaded. Check the screen you just locked in."
                        runCatching { RankingsStore.get(id) }.onSuccess { d ->
                            serverLog = d.log; log = d.log; row = d.row; changes = d.changes; reask = null; rebuild(d.cube?.cards)
                        }
                    } else {
                        error = "Couldn't save: ${e.message}. It's kept here and saves on the next lock-in."
                    }
                }
            bump()
        }
    }

    /** Watching: someone else's ranking every 10 s (60 s once nothing changed for a minute); yours every 60 s. */
    suspend fun watch() {
        while (kotlin.coroutines.coroutineContext.isActive) {
            val quiet = System.currentTimeMillis() - lastChange > 60_000
            delay(if (mine || quiet) 60_000 else 10_000)
            if (!saving && !unsaved) runCatching { RankingsStore.get(id) }.onSuccess { adopt(it); bump() }
        }
    }

    data class JobList(val placed: List<RankCard>, val rest: List<RankCard>, val restTitle: String?, val session: RankSession)

    /** A job's list: the placed cards, best first, then the rest by name. */
    fun list(job: RankJob): JobList? {
        val st = state ?: return null
        val s = st.session(job)
        val placed = s.top.mapNotNull(::cardAt)
        val inTop = s.top.toSet()
        val rest = st.scope(job).members.filter { it !in inTop }.mapNotNull(::cardAt).sortedBy { it.name.lowercase() }
        val title = when { rest.isEmpty() -> null; s.done -> "Below the top ${s.target}, in no particular order · ${rest.size}"; else -> "Not placed yet · ${rest.size}" }
        return JobList(placed, rest, title, s)
    }

    fun listText(job: RankJob): String {
        val l = list(job) ?: return ""
        val lines = l.placed.mapIndexed { i, c -> "${i + 1}. ${c.name}" }.toMutableList()
        if (l.restTitle != null && l.rest.isNotEmpty()) { lines += ""; lines += l.restTitle; lines += l.rest.map { it.name } }
        return lines.joinToString("\n") + "\n"
    }
}
