package site.table1.events.tracker

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import site.table1.events.T1App
import site.table1.events.data.Repo
import site.table1.events.data.TrackerGame
import site.table1.events.data.TrackerOp
import site.table1.events.data.TrackerState
import java.time.Instant

/**
 * One open tracker. Local sessions live only on this device; synced sessions (a match) push taps in
 * batches every ~300 ms from a persisted queue, and merge the other phone's taps from Realtime.
 * The whole session is saved on every change so closing the app never loses it.
 */
class TrackerController(context: Context, private val matchId: String?) {
    private val prefs = context.getSharedPreferences("t1.tracker", Context.MODE_PRIVATE)
    private val setupPrefs = context.getSharedPreferences("t1.tracker.setup", Context.MODE_PRIVATE)
    private val key = if (matchId == null) "local" else "match:$matchId"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val pushLock = Mutex()
    private var liveJob: Job? = null
    /** The round the live channel listens to; a different one (or a first one) re-joins. */
    private var liveRoundId: String? = null
    private var pushJob: Job? = null

    var doc by mutableStateOf<TrackerDoc?>(null)
        private set
    var error by mutableStateOf<String?>(null)
    /** Time of the latest change (local or remote); the screen re-checks open groups 2 s after it. */
    var lastChange by mutableLongStateOf(0L)
        private set
    var busy by mutableStateOf(false)
        private set

    val synced: Boolean get() = matchId != null

    fun start() {
        doc = load() ?: if (matchId == null) TrackerDoc(key = key, mySide = 0) else null
        if (matchId == null) return
        // Cached session first (works offline), then the server's state.
        doc?.sessionId?.let { startLive(it) }
        scope.launch {
            var backoff = 500L
            while (isActive) {
                val opened = runCatching { Repo.trackerOpen(matchId) }
                if (opened.isSuccess) {
                    val state = opened.getOrThrow()
                    applyState(state)
                    error = null
                    startLive(state.sessionId)
                    break
                }
                if (doc == null) error = opened.exceptionOrNull()?.message ?: "Couldn't open the tracker"
                delay(backoff)
                backoff = (backoff * 2).coerceAtMost(15_000)
            }
        }
        pushJob = scope.launch {
            var wait = 300L
            while (isActive) {
                delay(wait)
                wait = if (flush()) 300L else (wait * 2).coerceAtMost(10_000)
            }
        }
    }

    /** Leaving the screen: one last push of anything queued, then stop. The queue stays saved either way. */
    fun close() {
        liveJob?.cancel()
        pushJob?.cancel()
        scope.launch {
            withTimeoutOrNull(5_000) { flush() }
            scope.cancel()
        }
    }

    /** App going to the background. */
    fun flushSoon() {
        scope.launch { flush() }
    }

    /** Back in the foreground: catch up on anything missed. */
    fun refetch() {
        val sid = doc?.sessionId ?: return
        scope.launch { runCatching { Repo.trackerState(sid) }.onSuccess { applyState(it) } }
    }

    private fun startLive(sessionId: String) {
        val roundId = doc?.clock?.roundId
        if (liveJob?.isActive == true && liveRoundId == roundId) return
        liveJob?.cancel()
        liveRoundId = roundId
        liveJob = scope.launch {
            Repo.trackerChanges(sessionId, roundId).collect { change ->
                when (change) {
                    is Repo.TrackerChange.Op -> mergeOp(change.op)
                    is Repo.TrackerChange.Game -> mergeGame(change.game)
                    is Repo.TrackerChange.Clock -> doc?.let { d -> update(d.copy(clock = change.row.clock(d.clock))) }
                    Repo.TrackerChange.Resubscribed -> refetch()
                }
            }
        }
    }

    /* ── changes ─────────────────────────────────────────────────────────────── */

    fun tap(side: Int, counter: String, delta: Int) {
        val d = doc ?: return
        if (d.readOnly) return
        if (counter != "life") {
            val kind = d.counterKind(counter)
            val next = d.total(d.currentGame, side, counter) + delta
            if (kind?.min != null && next < kind.min) return
            if (kind?.max != null && next > kind.max) return
        }
        append(listOf(TrackerDoc.newOp(d.currentGame, side, counter, delta)))
    }

    fun undoLast() {
        val d = doc ?: return
        if (d.readOnly) return
        append(d.undoLastOps())
    }

    fun resetGame() {
        val d = doc ?: return
        if (d.readOnly) return
        if (!synced) {
            update(d.copy(ops = d.ops.filter { it.gameNo != d.currentGame }))
        } else {
            append(d.resetOps())
        }
    }

    /** Local only: a new table from Setup. Clears games, history and counter columns, names the players. */
    fun configure(players: Int, life: Int) {
        val d = doc ?: return
        if (synced) return
        val names = TrackerTable.names(players.coerceIn(2, 5))
        update(d.copy(names = names, startingLife = life, games = emptyList(), ops = emptyList(), promptedAt = 0,
            counterPrefs = names.map { CounterPrefs() }))
        setupPrefs.edit().putInt("players", players).putInt("life", life).apply()
    }

    /** The last setup used on this device (2 players, 20 life by default). */
    val lastSetup: Pair<Int, Int> get() =
        (setupPrefs.getInt("players", 2).takeIf { it in TrackerTable.playerChoices } ?: 2) to
            (setupPrefs.getInt("life", 20).takeIf { it in TrackerTable.lifeChoices } ?: 20)

    /** Shows or hides a counter column for one side (display only, kept on this device). */
    fun toggleCounter(side: Int, id: String) {
        val d = doc ?: return
        update(d.withCounterToggled(side, id))
    }

    /** Local: games and every game's totals back to the start; names, starting life and columns stay. */
    fun resetMatch() {
        val d = doc ?: return
        if (synced) return resetGame()
        update(d.copy(games = emptyList(), ops = emptyList(), promptedAt = 0))
    }

    /** Local: start over. */
    fun newMatch() {
        val d = doc ?: return
        if (synced) return
        update(d.copy(games = emptyList(), ops = emptyList(), promptedAt = 0,
            counterPrefs = d.names.map { CounterPrefs() }))
    }

    fun markPrompted() {
        val d = doc ?: return
        update(d.copy(promptedAt = d.games.size))
    }

    /** Called only after the player confirmed in the dialog. */
    fun recordGame(winnerSide: Int?, draw: Boolean) {
        val d = doc ?: return
        if (d.readOnly) return
        val game = d.currentGame
        if (!synced) {
            update(d.copy(games = d.games + TrackerGame(game, if (draw) null else winnerSide, draw, Instant.now().toString())))
            return
        }
        val sid = d.sessionId ?: run { error = "Still connecting — try again in a moment."; return }
        busy = true
        scope.launch {
            // Changes for a game must reach the server before the game is closed.
            flush()
            runCatching { Repo.trackerRecordGame(sid, game, if (draw) null else winnerSide, draw) }
                .onSuccess { applyState(it); error = null }
                .onFailure { error = it.message }
            busy = false
        }
    }

    /** Synced players: report the match through the existing report_match path (side-oriented scores). */
    suspend fun report(): Boolean {
        val d = doc ?: return false
        val mid = d.matchId ?: matchId ?: return false
        val side = d.mySide ?: return false
        return runCatching { Repo.reportFromHome(mid, side, d.wins(side), d.wins(1 - side), null, d.draws) }
            .onSuccess { doc?.let { cur -> update(cur.copy(promptedAt = cur.games.size)) }; error = null }
            .onFailure { error = it.message }
            .isSuccess
    }

    private fun append(newOps: List<TrackerOp>) {
        val d = doc ?: return
        val known = d.ops.mapTo(HashSet()) { it.clientOpId }
        val fresh = newOps.filter { it.clientOpId !in known }
        if (fresh.isEmpty()) return
        update(d.copy(ops = d.ops + fresh, pending = if (synced) d.pending + fresh.map { it.clientOpId } else d.pending))
        lastChange = System.currentTimeMillis()
    }

    /* ── sync ────────────────────────────────────────────────────────────────── */

    /** Pushes up to 200 queued ops. True when the queue is empty or the push worked. */
    private suspend fun flush(): Boolean {
        pushLock.withLock {
            return pushOnce()
        }
    }

    private suspend fun pushOnce(): Boolean {
        val d = doc ?: return true
        val sid = d.sessionId ?: return true
        if (d.readOnly || d.pending.isEmpty()) return true
        val waiting = d.pending.toHashSet()
        val batch = d.ops.filter { it.clientOpId in waiting }.take(200)
        if (batch.isEmpty()) {
            update(d.copy(pending = emptyList()))
            return true
        }
        val result = runCatching { Repo.trackerPush(sid, batch) }
        if (result.isSuccess) {
            val sent = batch.mapTo(HashSet()) { it.clientOpId }
            doc?.let { cur -> update(cur.copy(pending = cur.pending.filterNot { it in sent })) }
            return true
        }
        return false
    }

    private fun mergeOp(op: TrackerOp) {
        val d = doc ?: return
        if (d.ops.any { it.clientOpId == op.clientOpId }) return
        if (d.games.any { it.gameNo == op.gameNo }) return
        update(d.copy(ops = d.ops + op))
        lastChange = System.currentTimeMillis()
    }

    private fun mergeGame(game: TrackerGame) {
        val d = doc ?: return
        if (d.games.any { it.gameNo == game.gameNo }) return
        update(d.copy(games = (d.games + game).sortedBy { it.gameNo }))
        lastChange = System.currentTimeMillis()
    }

    /** Server state wins; local ops it hasn't seen yet stay queued (unless their game was already recorded). */
    private fun applyState(s: TrackerState) {
        val cur = doc
        val serverIds = s.ops.mapTo(HashSet()) { it.clientOpId }
        val recorded = s.games.mapTo(HashSet()) { it.gameNo }
        val waiting = cur?.pending?.toHashSet() ?: hashSetOf()
        val keep = cur?.ops.orEmpty().filter { it.clientOpId in waiting && it.clientOpId !in serverIds && it.gameNo !in recorded }
        update(
            TrackerDoc(
                key = key,
                synced = true,
                sessionId = s.sessionId,
                matchId = s.matchId ?: matchId,
                eventId = s.eventId,
                eventName = s.eventName,
                round = s.round,
                table = s.table,
                clock = s.clock,
                mySide = s.mySide,
                names = s.names?.takeIf { it.size >= 2 } ?: cur?.names ?: listOf("Player 1", "Player 2"),
                startingLife = s.startingLife,
                games = s.games.sortedBy { it.gameNo },
                ops = s.ops + keep,
                pending = keep.map { it.clientOpId },
                promptedAt = cur?.promptedAt ?: 0,
                counterPrefs = cur?.counterPrefs ?: listOf(CounterPrefs(), CounterPrefs()),
            ),
        )
        lastChange = System.currentTimeMillis()
    }

    /* ── persistence ─────────────────────────────────────────────────────────── */

    private fun update(next: TrackerDoc) {
        doc = next
        save(next)
    }

    private fun load(): TrackerDoc? = runCatching {
        prefs.getString(key, null)?.let { T1App.json.decodeFromString(TrackerDoc.serializer(), it) }
    }.getOrNull()

    private fun save(d: TrackerDoc) {
        runCatching { prefs.edit().putString(key, T1App.json.encodeToString(TrackerDoc.serializer(), d)).apply() }
    }
}

/** user_settings.tracker_mode, shared by Account, the event screen and the Events tab. Cached on device. */
object TrackerSettings {
    private val prefs get() = T1App.instance.getSharedPreferences("t1.settings", Context.MODE_PRIVATE)

    var mode by mutableStateOf(runCatching { prefs.getString("tracker_mode", null) }.getOrNull() ?: "elsewhere")
        private set

    val useTracker: Boolean get() = mode == "tracker"

    suspend fun refresh() {
        runCatching { Repo.trackerMode() }.onSuccess { cache(it) }
    }

    /** Optimistic; reverts and rethrows if the server refuses. */
    suspend fun set(next: String) {
        val previous = mode
        cache(next)
        runCatching { Repo.setTrackerMode(next) }.onFailure {
            cache(previous)
            throw it
        }
    }

    private fun cache(value: String) {
        mode = value
        runCatching { prefs.edit().putString("tracker_mode", value).apply() }
    }
}
