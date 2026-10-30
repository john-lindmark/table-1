package site.table1.events.widgets

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.os.SystemClock
import android.widget.RemoteViews
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.AndroidRemoteViews
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.Text
import androidx.glance.unit.ColorProvider
import androidx.compose.ui.graphics.toArgb
import site.table1.events.R
import site.table1.events.data.LiveSnapshot
import site.table1.events.data.NextEvent
import site.table1.events.data.NextEventItem
import site.table1.events.data.Repo
import site.table1.events.util.Telemetry
import java.text.NumberFormat
import java.util.Locale

/* The home screen widgets (contract/widgets-2026-10-22.md), drawn with Glance: Next event, Collection value and Current
   match, in the small and medium sizes iOS has. Lock Screen widgets have no Android equivalent; the live notification
   covers the match there. */

private val SMALL = DpSize(110.dp, 110.dp)
private val MEDIUM = DpSize(250.dp, 110.dp)

@Composable
private fun Label(text: String, color: androidx.compose.ui.graphics.Color = W1.muted) =
    Text(text.uppercase(), style = W1.label(color), maxLines = 1)

// ─────────────────────────────────────────────── Next event

class NextEventWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, MEDIUM))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = Widgets.nextFresh(context)
        provideContent {
            val shown = NextEvent.pick(data?.events.orEmpty())
            val medium = LocalSize.current.width >= MEDIUM.width
            val first = shown.firstOrNull()
            Column(GlanceModifier.fillMaxSize().background(W1.bg).padding(12.dp)
                .clickable(actionStartActivity(Widgets.open(context, first?.let { "table1://event/${it.id}?src=widget_next" } ?: "table1://events?src=widget_next")))) {
                when {
                    data == null && Repo.userId == null -> { Label("Table 1"); Spacer(GlanceModifier.height(6.dp)); Text("Sign in to see your events", style = W1.style()) }
                    first == null -> {
                        Label("Next event")
                        Spacer(GlanceModifier.defaultWeight())
                        Text("No events coming up", style = W1.style(14.sp))
                        Text("Create or join one", style = W1.style(11.sp, W1.muted))
                        if ((data?.invites ?: 0) > 0) Label("${data!!.invites} invite${if (data.invites == 1) "" else "s"}", W1.accent)
                    }
                    medium -> Row(GlanceModifier.fillMaxSize()) {
                        EventBlock(first, GlanceModifier.defaultWeight().fillMaxHeight())
                        Spacer(GlanceModifier.width(12.dp))
                        Column(GlanceModifier.defaultWeight().fillMaxHeight()) {
                            shown.getOrNull(1)?.let { e ->
                                Label("Then")
                                Text(e.name, style = W1.style(12.sp), maxLines = 2)
                                Label(NextEvent.timeText(e))
                            } ?: Label("Nothing after")
                            Spacer(GlanceModifier.defaultWeight())
                            if ((data?.invites ?: 0) > 0) Label("${data!!.invites} invite${if (data.invites == 1) "" else "s"}", W1.accent)
                        }
                    }
                    else -> EventBlock(first, GlanceModifier.fillMaxSize())
                }
            }
        }
    }

    @Composable
    private fun EventBlock(e: NextEventItem, modifier: GlanceModifier) {
        Column(modifier) {
            Label(e.label)
            Text(e.name, style = W1.style(14.sp, bold = true), maxLines = 2)
            Spacer(GlanceModifier.defaultWeight())
            Text(NextEvent.timeText(e), style = W1.style(13.sp, if (e.isLive) W1.accent else W1.text), maxLines = 1)
            e.venueName?.let { Label(it) }
            Label(listOfNotNull("${e.players} player${if (e.players == 1) "" else "s"}", if (e.organizing) "Organizing" else null).joinToString(" · "))
        }
    }
}

class NextEventWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = NextEventWidget()
}

// ─────────────────────────────────────────────── Collection value

class ValueWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, MEDIUM))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val r = Widgets.valueFresh(context)
        provideContent {
            val medium = LocalSize.current.width >= MEDIUM.width
            val money = NumberFormat.getCurrencyInstance(Locale.US)
            Column(GlanceModifier.fillMaxSize().background(W1.bg).padding(12.dp)
                .clickable(actionStartActivity(Widgets.open(context, "table1://collection?src=widget_value")))) {
                Label("Collection")
                val v = r?.current
                if (v == null) {
                    Spacer(GlanceModifier.defaultWeight())
                    Text(if (Repo.userId == null) "Sign in to see your collection" else "Open Collection once to start", style = W1.style(12.sp))
                    return@Column
                }
                Text(money.format(v), style = W1.style(if (medium) 22.sp else 18.sp, W1.text, bold = true), maxLines = 1)
                // The change includes cards added or removed, so it says "7 days", not "market".
                val c = r.change()
                Text(c?.let { (usd, days) -> (if (usd >= 0) "▲ " else "▼ ") + money.format(kotlin.math.abs(usd)) + " · $days day${if (days == 1) "" else "s"}" } ?: "From today",
                    style = W1.style(11.sp, if ((c?.first ?: 0.0) > 0) W1.accent else W1.muted), maxLines = 1)
                Spacer(GlanceModifier.defaultWeight())
                if (r.points.size >= 2) Image(ImageProvider(sparkline(r.points.map { it.usd }, if (medium) 480 else 220, 64)), "Value over 30 days",
                    GlanceModifier.fillMaxWidth().height(32.dp))
                if (medium) Label("${"%,d".format(r.cards)} cards · ${"%,d".format(r.copies)} copies")
            }
        }
    }

    private fun sparkline(values: List<Double>, w: Int, h: Int): Bitmap {
        val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val lo = values.min(); val hi = values.max(); val span = (hi - lo).takeIf { it > 0 } ?: 1.0
        val path = Path()
        values.forEachIndexed { i, v ->
            val x = i * (w - 2f) / (values.size - 1) + 1f
            val y = (h - 2f) - ((v - lo) / span).toFloat() * (h - 4f)
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        Canvas(b).drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = W1.accent.toArgb(); style = Paint.Style.STROKE; strokeWidth = 3f })
        return b
    }
}

class ValueWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ValueWidget()
}

// ─────────────────────────────────────────────── Current match

class MatchWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, MEDIUM))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val r = Widgets.liveFresh(context)
        provideContent {
            // The match you're playing now, else the live event you're in.
            val snap = r?.snapshots?.firstOrNull { it.state.isPlaying } ?: r?.snapshots?.firstOrNull { !it.state.ended }
            val medium = LocalSize.current.width >= MEDIUM.width
            Box(GlanceModifier.fillMaxSize().background(W1.bg).padding(12.dp)
                .clickable(actionStartActivity(Widgets.open(context, snap?.let { "table1://event/${it.eventId}?src=widget" } ?: "table1://events?src=widget")))) {
                if (snap == null) Column {
                    Label("Table 1")
                    Spacer(GlanceModifier.defaultWeight())
                    Text("No match right now", style = W1.style())
                } else if (medium) Row(GlanceModifier.fillMaxSize()) {
                    Small(context, snap, GlanceModifier.width(128.dp).fillMaxHeight())
                    Spacer(GlanceModifier.width(12.dp))
                    Column(GlanceModifier.defaultWeight().fillMaxHeight()) {
                        Label(snap.eventName)
                        Spacer(GlanceModifier.defaultWeight())
                        if (snap.state.isPlaying) Actions(snap) else Text(snap.state.statusLine, style = W1.style(12.sp, W1.muted), maxLines = 3)
                    }
                } else Small(context, snap, GlanceModifier.fillMaxSize())
            }
        }
    }

    @Composable
    private fun Small(context: Context, snap: LiveSnapshot, modifier: GlanceModifier) {
        val s = snap.state
        Column(modifier) {
            Label("${s.roundText} · ${s.tableText}", W1.accent)
            if (s.isPlaying) {
                Clock(context, s.endsAt, s.pausedRemaining)
                Spacer(GlanceModifier.defaultWeight())
                Text("vs ${s.oppName ?: "—"}", style = W1.style(13.sp), maxLines = 1)
                Label("${s.oppRankText} · ${s.oppRecord ?: "0-0"}")
                Label("You ${s.myRankText} · ${s.myRecord}", if (s.needsMyAnswer) W1.accent else W1.muted)
            } else {
                Spacer(GlanceModifier.defaultWeight())
                Text(s.statusLine, style = W1.style(13.sp), maxLines = 3)
                Label("You ${s.myRankText} · ${s.myRecord}", W1.accent)
            }
        }
    }

    /** The round clock ticks on the home screen (a Chronometer; Glance has none of its own). */
    @Composable
    private fun Clock(context: Context, endsAt: Double?, paused: Int?) {
        when {
            paused != null -> Text("%02d:%02d".format(paused / 60, paused % 60), style = W1.style(24.sp, W1.muted, bold = true))
            endsAt != null -> {
                val rv = RemoteViews(context.packageName, R.layout.widget_clock).apply {
                    val base = SystemClock.elapsedRealtime() + ((endsAt * 1000).toLong() - System.currentTimeMillis())
                    setChronometer(R.id.clock, base, null, true)
                    setChronometerCountDown(R.id.clock, true)
                }
                AndroidRemoteViews(rv)
            }
            else -> Text("—", style = W1.style(24.sp, W1.muted, bold = true))
        }
    }

    /** Report or answer without opening the app, as the iOS widget does. */
    @Composable
    private fun Actions(snap: LiveSnapshot) {
        val s = snap.state
        val match = s.matchId ?: return
        @Composable
        fun Button(label: String, op: String, my: Int = 0, their: Int = 0, modifier: GlanceModifier = GlanceModifier) {
            Box(modifier.background(W1.surface).padding(vertical = 8.dp)
                .clickable(actionRunCallback<ResultAction>(actionParametersOf(
                    ResultAction.Op to op, ResultAction.Match to match, ResultAction.Side to (s.mySide ?: 0),
                    ResultAction.My to my, ResultAction.Their to their, ResultAction.Version to (s.matchVersion ?: -1)))),
                contentAlignment = Alignment.Center) {
                Text(label, style = W1.style(12.sp, if (op == "confirm") W1.accent else W1.text))
            }
        }
        when {
            s.needsMyAnswer -> Row(GlanceModifier.fillMaxWidth()) {
                Button("Confirm", "confirm", modifier = GlanceModifier.defaultWeight())
                Spacer(GlanceModifier.width(1.dp))
                Button("Dispute", "dispute", modifier = GlanceModifier.defaultWeight())
            }
            s.canReportNow -> Column {
                Row(GlanceModifier.fillMaxWidth()) {
                    Button("2-0", "report", 2, 0, GlanceModifier.defaultWeight()); Spacer(GlanceModifier.width(1.dp))
                    Button("2-1", "report", 2, 1, GlanceModifier.defaultWeight()); Spacer(GlanceModifier.width(1.dp))
                    Button("1-1", "report", 1, 1, GlanceModifier.defaultWeight())
                }
                Spacer(GlanceModifier.height(1.dp))
                Row(GlanceModifier.fillMaxWidth()) {
                    Button("1-2", "report", 1, 2, GlanceModifier.defaultWeight()); Spacer(GlanceModifier.width(1.dp))
                    Button("0-2", "report", 0, 2, GlanceModifier.defaultWeight())
                }
            }
            else -> Text(s.statusLine, style = W1.style(12.sp, W1.muted), maxLines = 3)
        }
    }
}

class MatchWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = MatchWidget()
}

/** Report / Confirm / Dispute from the Current match widget. */
class ResultAction : ActionCallback {
    companion object {
        val Op = ActionParameters.Key<String>("op")
        val Match = ActionParameters.Key<String>("match")
        val Side = ActionParameters.Key<Int>("side")
        val My = ActionParameters.Key<Int>("my")
        val Their = ActionParameters.Key<Int>("their")
        val Version = ActionParameters.Key<Int>("version")
    }

    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val match = parameters[Match] ?: return
        val op = parameters[Op] ?: return
        runCatching {
            when (op) {
                "report" -> Repo.reportFromHome(match, parameters[Side] ?: 0, parameters[My] ?: 0, parameters[Their] ?: 0, parameters[Version]?.takeIf { it >= 0 })
                "confirm" -> Repo.respondToResult(match, true)
                "dispute" -> Repo.respondToResult(match, false)
            }
        }.onSuccess { Telemetry.capture("live_activity_action", mapOf("action" to op, "surface" to "widget")) }
        Repo.liveState()
        MatchWidget().update(context, glanceId)
    }
}
