package site.table1.events.util

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import site.table1.events.MainActivity
import site.table1.events.R
import site.table1.events.T1App
import site.table1.events.data.LiveSnapshot
import site.table1.events.data.LiveState
import site.table1.events.data.LiveStateResponse
import site.table1.events.data.OrgState
import site.table1.events.data.OrganizerSnapshot
import site.table1.events.data.Repo
import site.table1.events.widgets.Widgets

/**
 * Android's Live Activities (contract/widgets-2026-10-22.md): one ongoing notification per live event you play in
 * (round, table, opponent, the round clock counting down, where the result stands, and Report / Confirm / Dispute
 * from the shade) and one per event you run (results in as a bar, disputes, the next step). On Android 16 they ask
 * to be promoted as Live Updates (chip in the status bar, top of the lock screen). Silent channel: alerts come as
 * ordinary pushes. Fed by live-activity's `state` whenever the app reads it, and by its `live.*` FCM messages.
 */
object LiveUpdates {
    const val CHANNEL = "live"
    private const val PREFS = "t1.live"
    private val json = Json { ignoreUnknownKeys = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var refreshing: Job? = null

    fun channel(context: Context) {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Live events", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Your match and the round clock while you play; results coming in while you run an event"
                setShowBadge(false)
            },
        )
    }

    /** Reads `state` again (a push about an event came in, the app came back, a result was sent from the shade). */
    fun refresh(context: Context) {
        if (refreshing?.isActive == true) return
        refreshing = scope.launch {
            if (T1App.supabase.auth.sessionStatus.value !is SessionStatus.Authenticated) return@launch
            Repo.liveState() // shows itself
            Widgets.updateMatch(context)
        }
    }

    /** Everything `state` returned: draws what's live, lets go of what's over or gone. */
    fun show(context: Context, r: LiveStateResponse) {
        Widgets.saveLive(context, r)
        val keep = mutableSetOf<String>()
        for (s in r.snapshots) if (player(context, s)) keep += key("p", s.eventId)
        for (o in r.organizer) if (organizer(context, o)) keep += key("o", o.eventId)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val before = prefs.getStringSet("shown", emptySet()).orEmpty()
        val nm = NotificationManagerCompat.from(context)
        for (gone in before - keep) {
            nm.cancel(gone, 0)
            Telemetry.capture("live_activity_ended", mapOf("type" to if (gone.startsWith("p:")) "player" else "organizer", "reason" to "gone"))
        }
        for (new in keep - before) Telemetry.capture("live_activity_started", mapOf("type" to if (new.startsWith("p:")) "player" else "organizer"))
        prefs.edit().putStringSet("shown", keep).apply()
    }

    /** A `live.player` / `live.organizer` FCM message: the state is in it, so no round trip. */
    fun onPush(context: Context, data: Map<String, String>) {
        val raw = data["live"] ?: return refresh(context)
        runCatching {
            when (data["kind"]) {
                "live.player" -> json.decodeFromString<LiveSnapshot>(raw).let { s ->
                    if (player(context, s)) remember(context, key("p", s.eventId)) else forget(context, key("p", s.eventId))
                }
                "live.organizer" -> json.decodeFromString<OrganizerSnapshot>(raw).let { o ->
                    if (organizer(context, o)) remember(context, key("o", o.eventId)) else forget(context, key("o", o.eventId))
                }
            }
        }.onFailure { refresh(context) }
        Widgets.updateMatch(context)
    }

    /** Signed out: nothing of the old account stays in the shade. */
    fun clear(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getStringSet("shown", emptySet()).orEmpty().forEach { NotificationManagerCompat.from(context).cancel(it, 0) }
        prefs.edit().clear().apply()
    }

    private fun key(type: String, eventId: String) = "$type:$eventId"

    private fun remember(context: Context, k: String) {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val s = p.getStringSet("shown", emptySet()).orEmpty()
        if (k !in s) Telemetry.capture("live_activity_started", mapOf("type" to if (k.startsWith("p:")) "player" else "organizer"))
        p.edit().putStringSet("shown", s + k).apply()
    }

    private fun forget(context: Context, k: String) {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        p.edit().putStringSet("shown", p.getStringSet("shown", emptySet()).orEmpty() - k).apply()
    }

    private fun open(context: Context, eventId: String, src: String): PendingIntent {
        val i = Intent(context, MainActivity::class.java)
            .setData(Uri.parse("table1://event/$eventId?src=$src"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(context, "$src:$eventId".hashCode(), i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun base(context: Context, eventId: String, src: String) = NotificationCompat.Builder(context, CHANNEL)
        .setSmallIcon(R.drawable.ic_stat_t1)
        .setColor(context.getColor(R.color.t1_accent))
        .setContentIntent(open(context, eventId, src))
        .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setOnlyAlertOnce(true)
        .setSilent(true)

    /** The round clock: a countdown to endsAt while it runs, the time left while paused. */
    private fun NotificationCompat.Builder.clock(endsAt: Double?, paused: String?): NotificationCompat.Builder {
        if (endsAt != null && paused == null) {
            setWhen((endsAt * 1000).toLong()).setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true)
        } else setShowWhen(false)
        return this
    }

    /** Android 16 Live Updates: ongoing, with a title, asks to be promoted. Older versions ignore the extra. */
    private fun NotificationCompat.Builder.promoted(): NotificationCompat.Builder {
        if (Build.VERSION.SDK_INT >= 36) addExtras(android.os.Bundle().apply { putBoolean("android.requestPromotedOngoing", true) })
        return this
    }

    private fun post(context: Context, k: String, n: android.app.Notification): Boolean {
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return false
        return runCatching { nm.notify(k, 0, n) }.isSuccess
    }

    /** True while it stays in the shade. */
    private fun player(context: Context, snap: LiveSnapshot): Boolean {
        val s = snap.state
        val k = key("p", snap.eventId)
        val name = snap.eventName.ifEmpty { "Your event" }
        val b = base(context, snap.eventId, "live_activity")
        if (s.ended) {
            // The last word stays a while, like a Live Activity's dismissal date, then goes.
            b.setContentTitle(name).setContentText(s.statusLine).setOngoing(false).setAutoCancel(true)
                .setTimeoutAfter(if (s.phase == "dropped") 1L else 30 * 60 * 1000L)
            post(context, k, b.build())
            return false
        }
        val paused = s.pausedRemaining?.let { "%02d:%02d".format(it / 60, it % 60) }
        b.setContentTitle(if (s.isPlaying) "${s.roundText} · ${s.tableText} · vs ${s.oppName ?: "—"}" else "$name · ${s.roundText}")
            .setContentText(s.statusLine)
            .setSubText(if (s.isPlaying) "$name${paused?.let { " · paused $it" } ?: ""}" else "You ${s.myRankText} · ${s.myRecord}")
            .setStyle(NotificationCompat.BigTextStyle().bigText(listOfNotNull(s.statusLine,
                if (s.isPlaying) "${s.oppName ?: "Opponent"} ${s.oppRankText}${s.oppRecord?.let { " · $it" } ?: ""} · you ${s.myRankText} · ${s.myRecord}" else null,
            ).joinToString("\n")))
            .setOngoing(true)
            .clock(if (s.isPlaying) s.endsAt else null, paused)
            .promoted()
        actions(context, snap).forEach { b.addAction(it) }
        return post(context, k, b.build())
    }

    /** Report or answer from the shade, as iOS's Live Activity buttons do; anything else opens the event. */
    private fun actions(context: Context, snap: LiveSnapshot): List<NotificationCompat.Action> {
        val s = snap.state
        val match = s.matchId ?: return emptyList()
        fun act(label: String, op: String, my: Int = 0, their: Int = 0): NotificationCompat.Action {
            val i = Intent(context, LiveActionReceiver::class.java).setAction(LiveActionReceiver.ACTION)
                .putExtra("op", op).putExtra("match", match).putExtra("side", s.mySide ?: 0)
                .putExtra("my", my).putExtra("their", their).putExtra("version", s.matchVersion ?: -1)
            val pi = PendingIntent.getBroadcast(context, "$op$my$their$match".hashCode(), i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            return NotificationCompat.Action(0, label, pi)
        }
        return when {
            s.needsMyAnswer -> listOf(act("Confirm", "confirm"), act("Dispute", "dispute"))
            s.canReportNow -> listOf(act("Won 2–0", "report", 2, 0), act("Won 2–1", "report", 2, 1),
                NotificationCompat.Action(0, "Other result", open(context, snap.eventId, "live_activity_report")))
            else -> emptyList()
        }
    }

    private fun organizer(context: Context, snap: OrganizerSnapshot): Boolean {
        val s: OrgState = snap.state
        val k = key("o", snap.eventId)
        val b = base(context, snap.eventId, "organizer_activity")
        if (s.ended) {
            b.setContentTitle(snap.eventName).setContentText(s.nextStep).setOngoing(false).setAutoCancel(true).setTimeoutAfter(30 * 60 * 1000L)
            post(context, k, b.build())
            return false
        }
        val lines = listOf(s.nextStep) + s.flags
        b.setContentTitle("${snap.eventName} · ${s.roundText}")
            .setContentText(if (s.isLive && s.matches > 0) "${s.resultsText} · ${s.nextStep}" else s.nextStep)
            .setSubText(if (s.isLive) s.resultsText + (s.pausedText?.let { " · paused $it" } ?: "") else null)
            .setStyle(NotificationCompat.BigTextStyle().bigText(lines.joinToString("\n")))
            .setOngoing(true)
            .clock(if (s.isLive) s.endsAt else null, s.pausedText)
            .promoted()
        if (s.isLive && s.matches > 0) b.setProgress(s.matches, s.done, false)
        return post(context, k, b.build())
    }
}

/** Report / Confirm / Dispute from the live notification. */
class LiveActionReceiver : BroadcastReceiver() {
    companion object { const val ACTION = "site.table1.events.LIVE_ACTION" }

    override fun onReceive(context: Context, intent: Intent) {
        val match = intent.getStringExtra("match") ?: return
        val op = intent.getStringExtra("op") ?: return
        val done = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                runCatching {
                    when (op) {
                        "report" -> Repo.reportFromHome(match, intent.getIntExtra("side", 0), intent.getIntExtra("my", 0), intent.getIntExtra("their", 0),
                            intent.getIntExtra("version", -1).takeIf { it >= 0 })
                        "confirm" -> Repo.respondToResult(match, true)
                        "dispute" -> Repo.respondToResult(match, false)
                    }
                }.onSuccess { Telemetry.capture("live_activity_action", mapOf("action" to op, "surface" to "notification")) }
                Repo.liveState()
                Widgets.updateMatch(context)
            } finally {
                done.finish()
            }
        }
    }
}
