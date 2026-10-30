package site.table1.events.widgets

import android.content.Context
import androidx.glance.GlanceId
import androidx.glance.LocalSize
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.provideContent
import site.table1.events.data.Repo
import site.table1.events.util.Telemetry

/* The home screen widgets (contract/widgets-2026-10-22.md § Android): Next event, Collection value and Current match.
   These classes load the data and say where taps go; WidgetViews.kt draws them, at whatever size the widget is resized
   to (SizeMode.Exact: one row up to full width and as tall as the launcher allows). Lock Screen widgets have no Android
   equivalent; the live notification covers the match there. */

// ─────────────────────────────────────────────── Next event

class NextEventWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = Widgets.nextFresh(context)
        provideContent {
            NextEventContent(data, signedIn = data != null || Repo.userId != null, size = LocalSize.current, open = { e ->
                actionStartActivity(Widgets.open(context, e?.let { "table1://event/${it.id}?src=widget_next" } ?: "table1://events?src=widget_next"))
            })
        }
    }
}

class NextEventWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = NextEventWidget()
}

// ─────────────────────────────────────────────── Collection value

class ValueWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val r = Widgets.valueFresh(context)
        provideContent {
            ValueContent(r, signedIn = Repo.userId != null, size = LocalSize.current,
                tap = actionStartActivity(Widgets.open(context, "table1://collection?src=widget_value")))
        }
    }
}

class ValueWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ValueWidget()
}

// ─────────────────────────────────────────────── Current match

class MatchWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val r = Widgets.liveFresh(context)
        provideContent {
            // The match you're playing now, else the live event you're in.
            val snap = r?.snapshots?.firstOrNull { it.state.isPlaying } ?: r?.snapshots?.firstOrNull { !it.state.ended }
            val s = snap?.state
            MatchContent(snap, LocalSize.current,
                tap = actionStartActivity(Widgets.open(context, snap?.let { "table1://event/${it.eventId}?src=widget" } ?: "table1://events?src=widget")),
                // Report or answer without opening the app, as the iOS widget does.
                act = { op, my, their ->
                    actionRunCallback<ResultAction>(actionParametersOf(
                        ResultAction.Op to op, ResultAction.Match to (s?.matchId ?: ""), ResultAction.Side to (s?.mySide ?: 0),
                        ResultAction.My to my, ResultAction.Their to their, ResultAction.Version to (s?.matchVersion ?: -1)))
                })
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
        val match = parameters[Match]?.takeIf { it.isNotEmpty() } ?: return
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
