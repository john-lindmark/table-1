package site.table1.events.widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.LocalSize
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.provideContent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.theme.T1
import site.table1.events.ui.theme.Table1Theme
import site.table1.events.util.Telemetry

/* Meta breakdown, Matchup grid and Archetype matchups (contract/widgets-2026-10-22.md § Meta widgets). Each widget is
   set up on its own settings screen (MetaWidgetConfigActivity: when it's placed on Android 11 and older, and from the
   widget's long-press Reconfigure / settings on 12+, where it's placed on Modern, Big events, 30 days). The pack is
   public, so they work signed out. MetaWidgetViews.kt draws them. */

private data class MetaState(val picks: MetaPicks, val pack: MetaPack?, val selection: String?)

private suspend fun metaPick(context: Context, id: GlanceId): MetaState {
    val widgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
    val picks = MetaPacks.picks(context, widgetId)
    return MetaState(picks, withContext(Dispatchers.IO) { MetaPacks.fresh(context, picks.format) }, MetaPacks.selection(context, widgetId))
}

/** A tap on a grid square or a Meta row: picks it on that widget (or lets it go) and redraws the widget. */
class MetaSelectAction : ActionCallback {
    companion object {
        val Value = ActionParameters.Key<String>("value")
        val Kind = ActionParameters.Key<String>("kind")
        fun of(kind: String, value: String) = actionRunCallback<MetaSelectAction>(actionParametersOf(Kind to kind, Value to value))
    }

    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val value = parameters[Value] ?: return
        MetaPacks.toggle(context, GlanceAppWidgetManager(context).getAppWidgetId(glanceId), value)
        Telemetry.capture("widget_tapped", mapOf("widget" to (parameters[Kind] ?: ""), "what" to if (":" in value) "cell" else "row"))
        (if (parameters[Kind] == "grid") MatchupGridWidget() else MetaWidget()).update(context, glanceId)
    }
}

class MetaWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val (picks, pack, sel) = metaPick(context, id)
        provideContent {
            MetaContent(pack, picks, LocalSize.current, actionStartActivity(Widgets.open(context, picks.link(null, "widget_meta"))),
                focus = sel?.toIntOrNull(), select = { MetaSelectAction.of("meta", it) })
        }
    }
}

class MatchupGridWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val (picks, pack, sel) = metaPick(context, id)
        provideContent {
            MatchupGridContent(pack, picks, LocalSize.current, actionStartActivity(Widgets.open(context, picks.link("matchups", "widget_grid"))),
                selected = MetaWidgets.cellOf(sel), select = { MetaSelectAction.of("grid", it) })
        }
    }
}

class ArchetypeWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val (picks, pack) = metaPick(context, id)
        val a = pack?.let { MetaWidgets.archetypeFor(it, picks) }
        provideContent {
            ArchetypeContent(pack, picks, LocalSize.current,
                actionStartActivity(Widgets.open(context, picks.link(a?.let { "archetype/$it" }, "widget_archetype"))))
        }
    }
}

/** A removed widget's picks go with it. */
abstract class MetaReceiver : GlanceAppWidgetReceiver() {
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        MetaPacks.forget(context, appWidgetIds)
    }
}

class MetaWidgetReceiver : MetaReceiver() { override val glanceAppWidget: GlanceAppWidget = MetaWidget() }
class MatchupGridWidgetReceiver : MetaReceiver() { override val glanceAppWidget: GlanceAppWidget = MatchupGridWidget() }
class ArchetypeWidgetReceiver : MetaReceiver() { override val glanceAppWidget: GlanceAppWidget = ArchetypeWidget() }

/** A widget's settings: format, events, window and, for Archetype matchups, the archetype (iOS's Edit Widget). */
class MetaWidgetConfigActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val widgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        // Backing out leaves a newly placed widget unplaced (Android 11 and older) and an old one as it was.
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        val provider = AppWidgetManager.getInstance(this).getAppWidgetInfo(widgetId)?.provider?.className ?: ""
        val kind = when (provider) {
            MatchupGridWidgetReceiver::class.java.name -> "grid"
            ArchetypeWidgetReceiver::class.java.name -> "archetype"
            else -> "meta"
        }
        val start = MetaPacks.picks(this, widgetId)
        setContent {
            Table1Theme {
                MetaSettings(kind, start, onBack = ::finish) { picks ->
                    MetaPacks.savePicks(this, widgetId, picks)
                    Telemetry.capture("widget_configured", mapOf("widget" to kind, "format" to picks.format, "tier" to picks.tier,
                        "days" to picks.days, "archetype" to (picks.archetype != null)))
                    val (widget, receiver) = when (kind) {
                        "grid" -> MatchupGridWidget() to MatchupGridWidgetReceiver::class.java
                        "archetype" -> ArchetypeWidget() to ArchetypeWidgetReceiver::class.java
                        else -> MetaWidget() to MetaWidgetReceiver::class.java
                    }
                    Widgets.refresh(applicationContext, widget, receiver)
                    setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
                    finish()
                }
            }
        }
    }
}

@Composable
private fun MetaSettings(kind: String, start: MetaPicks, onBack: () -> Unit, onSave: (MetaPicks) -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var picks by remember { mutableStateOf(start) }
    var pack by remember { mutableStateOf<MetaPack?>(null) }
    val scope = rememberCoroutineScope()
    if (kind == "archetype") LaunchedEffect(picks.format) {
        pack = MetaPacks.load(context, picks.format)
        pack = withContext(Dispatchers.IO) { MetaPacks.fresh(context, picks.format) } ?: pack
    }
    val formats = MetaFormats.all
    val windows = listOf(7, 14, 30, 90)
    Column(Modifier.fillMaxSize().background(T1.bg).systemBarsPadding()) {
        Bar(when (kind) { "grid" -> "Matchup grid"; "archetype" -> "Archetype matchups"; else -> "Meta" }, onBack = onBack)
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Label("Format")
            T1Segmented(formats.map { MetaFormats.short(it.first) }, formats.indexOfFirst { it.first == picks.format }.coerceAtLeast(0), scroll = true) {
                // An archetype belongs to its format.
                picks = picks.copy(format = formats[it].first, archetype = null)
            }
            Label("Events")
            T1Segmented(listOf("Big events", "All events"), if (picks.tier == "all") 1 else 0) { picks = picks.copy(tier = if (it == 1) "all" else "big") }
            Label("Window")
            T1Segmented(windows.map { "${it}D" }, windows.indexOf(picks.days).coerceAtLeast(0)) { picks = picks.copy(days = windows[it]) }
            if (kind == "archetype") Label("Archetype")
        }
        if (kind == "archetype") {
            val p = pack
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                item {
                    ListRow("Most played", onClick = { picks = picks.copy(archetype = null) }) {
                        if (picks.archetype == null) Label("Picked", color = T1.accent)
                    }
                }
                if (p == null) item { ListRow("${MetaFormats.name(picks.format)} loads when you're online") }
                else items(MetaWidgets.choices(p)) { a ->
                    ListRow(p.name(a), onClick = { picks = picks.copy(archetype = a) }) {
                        if (picks.archetype == a) Label("Picked", color = T1.accent)
                    }
                }
            }
        } else {
            Column(Modifier.weight(1f)) {}
        }
        BigAction("Save", accent = false) { scope.launch { onSave(picks) } }
    }
}
