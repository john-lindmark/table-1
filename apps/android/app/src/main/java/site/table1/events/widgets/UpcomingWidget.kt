package site.table1.events.widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.provideContent
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.Text
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.data.FindFilters
import site.table1.events.data.FoundEvent
import site.table1.events.data.Leagues
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label as UiLabel
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Section
import site.table1.events.ui.theme.T1
import site.table1.events.ui.theme.Table1Theme
import site.table1.events.util.Telemetry
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlin.math.floor

/* The Upcoming events widget (contract/public-events-leagues-2026-11-13.md § 6): the next events you can find, from
   find_events (public ones signed out; your friends' too when the app is signed in), cut by the widget's own Formats
   and Where, set up on UpcomingWidgetConfigActivity. Near me reads the app's last rough place and never asks. */

/** What an Upcoming events widget shows: any of the format keys (none = all), near the device or everywhere. */
@Serializable
data class UpcomingPicks(val formats: List<String> = emptyList(), val near: Boolean = true)

/** The app's last rough place (rounded to 0.1°, about 11 km), kept on the device only: written when the app reads a
 *  fix with location already allowed, read by the widget's Near me. */
object UpcomingPlace {
    private fun prefs(context: Context) = context.getSharedPreferences("t1.widgets.upcoming", Context.MODE_PRIVATE)

    fun save(context: Context, lat: Double, lng: Double) {
        prefs(context).edit().putFloat("place.lat", Leagues.rough(lat).toFloat()).putFloat("place.lng", Leagues.rough(lng).toFloat()).apply()
    }

    fun load(context: Context): Pair<Double, Double>? {
        val p = prefs(context)
        if (!p.contains("place.lat") || !p.contains("place.lng")) return null
        // Back through the rounding: a float's 39.7 reads 39.70000076.
        return Leagues.rough(p.getFloat("place.lat", 0f).toDouble()) to Leagues.rough(p.getFloat("place.lng", 0f).toDouble())
    }
}

object UpcomingWidgets {
    /** Near me's reach. */
    const val KM = 100

    data class Row(val id: String, val at: String, val name: String, val line: String, val live: Boolean, val joined: Boolean)

    /** A row: `SUN 29 · 10:00` (or `NOW · ROUND 3`), the name, `MODERN · MEH GAMES`; [joined] draws IN. */
    fun row(e: FoundEvent, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): Row {
        val running = (e.status == "seated" || e.status == "in_progress") && e.currentRound > 0
        val at = if (running) "NOW · ROUND ${e.currentRound}" else Leagues.parseInstant(e.startsAt)?.let { Leagues.dayText(it, zone, locale) } ?: "SOON"
        return Row(e.eventId, at, e.name, listOfNotNull(e.formatLabel.uppercase().ifEmpty { null }, e.venueName?.uppercase()?.ifEmpty { null }).joinToString(" · "),
            running, e.me != null)
    }

    /** What find_events is asked: the picked formats, and with Near me and a place, events within [KM] of it. */
    fun filters(picks: UpcomingPicks, place: Pair<Double, Double>?): Pair<FindFilters, Pair<Double, Double>?> {
        val here = place.takeIf { picks.near }
        return FindFilters(formats = Leagues.formatKeys.map { it.first }.filter { it in picks.formats }, km = here?.let { KM }) to here
    }

    /** The picked formats for the empty widget and the settings row: `ALL FORMATS`, `MODERN`, `MODERN · LEGACY`, `4 FORMATS`. */
    fun formatsLine(picks: UpcomingPicks): String {
        val labels = Leagues.formatKeys.filter { it.first in picks.formats }.map { it.second.uppercase() }
        return when (labels.size) { 0 -> "ALL FORMATS"; 1, 2 -> labels.joinToString(" · "); else -> "${labels.size} FORMATS" }
    }

    /** How many rows a widget of this height lists under its header (the gallery checks the fit). */
    fun rowCount(height: Float, wide: Boolean): Int = floor((height - 58f) / (if (wide) 36f else 50f)).toInt().coerceIn(1, 8)

    fun eventLink(id: String) = "table1://event/$id?src=widget_upcoming"
    const val FIND_LINK = "table1://find?src=widget_upcoming"
}

/** Each widget's picks and the events last read for them, on the device. Read again when older than 25 minutes (the
 *  launcher asks every 30), with an 8 s limit; the held rows stay when the network or the server says no. */
object UpcomingEvents {
    private const val PREFS = "t1.widgets.upcoming"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val list = ListSerializer(FoundEvent.serializer())
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun picks(context: Context, widgetId: Int): UpcomingPicks =
        prefs(context).getString("picks.$widgetId", null)?.let { runCatching { json.decodeFromString(UpcomingPicks.serializer(), it) }.getOrNull() } ?: UpcomingPicks()

    fun savePicks(context: Context, widgetId: Int, picks: UpcomingPicks) {
        prefs(context).edit().putString("picks.$widgetId", json.encodeToString(UpcomingPicks.serializer(), picks)).apply()
    }

    fun forget(context: Context, widgetIds: IntArray) {
        prefs(context).edit().apply { widgetIds.forEach { remove("picks.$it"); remove("events.$it"); remove("at.$it") } }.apply()
    }

    private fun held(context: Context, widgetId: Int): List<FoundEvent>? =
        prefs(context).getString("events.$widgetId", null)?.let { runCatching { json.decodeFromString(list, it) }.getOrNull() }

    suspend fun fresh(context: Context, widgetId: Int, picks: UpcomingPicks, maxAgeMs: Long = 25 * 60_000L): List<FoundEvent>? {
        val p = prefs(context)
        val held = held(context, widgetId)
        val key = "${picks.formats.joinToString(",")}|${picks.near}"
        if (held != null && p.getString("for.$widgetId", null) == key && System.currentTimeMillis() - p.getLong("at.$widgetId", 0) < maxAgeMs) return held
        val (filters, here) = UpcomingWidgets.filters(picks, UpcomingPlace.load(context))
        val events = withTimeoutOrNull(8_000) {
            // Signed in, friends' events come too; a widget can run before the app has read its saved session.
            withTimeoutOrNull(3_000) { runCatching { T1App.supabase.auth.awaitInitialization() } }
            runCatching {
                T1App.supabase.postgrest.rpc("find_events", buildJsonObject { put("p_filters", filters.json(here = here)); put("p_limit", 12) }).decodeList<FoundEvent>()
            }.getOrNull()
        } ?: return held.takeIf { p.getString("for.$widgetId", null) == key }
        p.edit().putString("events.$widgetId", json.encodeToString(list, events)).putString("for.$widgetId", key)
            .putLong("at.$widgetId", System.currentTimeMillis()).apply()
        return events
    }

    fun refresh(context: Context) = Widgets.refresh(context, UpcomingWidget(), UpcomingWidgetReceiver::class.java)
}

class UpcomingWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val widgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
        val picks = UpcomingEvents.picks(context, widgetId)
        val events = UpcomingEvents.fresh(context, widgetId, picks)
        provideContent {
            UpcomingContent(events, picks, LocalSize.current, find = actionStartActivity(Widgets.open(context, UpcomingWidgets.FIND_LINK)),
                open = { e -> actionStartActivity(Widgets.open(context, UpcomingWidgets.eventLink(e.eventId))) })
        }
    }
}

class UpcomingWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = UpcomingWidget()
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        UpcomingEvents.forget(context, appWidgetIds)
    }
}

@Composable
private fun UT(text: String, size: TextUnit = 13.sp, color: Color = W1.text, bold: Boolean = false, lines: Int = 1, modifier: GlanceModifier = GlanceModifier) =
    Text(text, modifier, style = W1.style(size, color, bold), maxLines = lines)

/** What the widget draws, on events passed in so WidgetGalleryTest can draw it. The header (and anywhere that isn't a
 *  row) opens Find; a row opens its event. */
@Composable
internal fun UpcomingContent(events: List<FoundEvent>?, picks: UpcomingPicks, size: DpSize, find: Action, open: (FoundEvent) -> Action,
                             zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()) {
    val shape = WShape.of(size)
    val first = events?.firstOrNull()
    // One event shown: the whole widget is that event.
    val single = first != null && (shape.strip || shape == WShape.SMALL)
    WidgetFrame(shape, if (single) open(first!!) else find) {
        if (first == null) {
            Label("Upcoming events", W1.accent)
            if (!shape.strip) Spacer(GlanceModifier.defaultWeight()) else Spacer(GlanceModifier.height(2.dp))
            UT("No events", if (shape.tall) 15.sp else 13.sp)
            if (!shape.strip) { Spacer(GlanceModifier.height(4.dp)); Label(UpcomingWidgets.formatsLine(picks)) }
            return@WidgetFrame
        }
        val r = UpcomingWidgets.row(first, zone, locale)
        when {
            shape == WShape.STRIP -> {
                UT(r.at, 13.sp, if (r.live || r.joined) W1.accent else W1.text, bold = true)
                Spacer(GlanceModifier.height(2.dp))
                UT(r.name, 12.sp)
            }
            shape == WShape.WIDE_STRIP -> Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(GlanceModifier.defaultWeight()) {
                    Label(if (r.joined) "In" else "Upcoming", if (r.joined) W1.accent else W1.muted)
                    Spacer(GlanceModifier.height(2.dp))
                    UT(r.at, 15.sp, if (r.live) W1.accent else W1.text, bold = true)
                }
                Spacer(GlanceModifier.width(12.dp))
                Column(GlanceModifier.defaultWeight()) {
                    UT(r.name, 13.sp)
                    Spacer(GlanceModifier.height(2.dp))
                    Label(r.line)
                }
            }
            shape == WShape.SMALL -> {
                // The next event: day and time large, name, format · venue.
                Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Label("Upcoming", W1.accent, GlanceModifier.defaultWeight())
                    if (r.joined) Label("In", W1.accent)
                }
                Spacer(GlanceModifier.height(6.dp))
                // Bold glyphs run a little wider than the 0.6 em the fit assumes: leave them room.
                UT(r.at, WidgetText.fit(r.at, size.width - 48.dp, 18f).sp, if (r.live) W1.accent else W1.text, bold = true)
                Spacer(GlanceModifier.defaultWeight())
                UT(r.name, 14.sp, lines = 2)
                Spacer(GlanceModifier.height(4.dp))
                Label(r.line)
            }
            else -> {
                Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    // A narrow widget has room for the name alone; the picks are in its settings.
                    Label(if (shape.wide) "Upcoming events" else "Upcoming", W1.accent, GlanceModifier.defaultWeight())
                    if (shape.wide) Label(UpcomingWidgets.formatsLine(picks))
                }
                Spacer(GlanceModifier.height(8.dp))
                val rows = events.take(UpcomingWidgets.rowCount(size.height.value, shape.wide))
                // Glance draws at most ten children per column: group the rows.
                rows.chunked(4).forEach { group ->
                    Column(GlanceModifier.fillMaxWidth()) { group.forEach { e -> UpcomingRow(UpcomingWidgets.row(e, zone, locale), shape.wide, open(e)) } }
                }
            }
        }
    }
}

/** Wide: `SUN 29 · 10:00` beside the name, format · venue under it. Narrow: the three stacked. IN in accent at the end. */
@Composable
private fun UpcomingRow(r: UpcomingWidgets.Row, wide: Boolean, tap: Action) {
    if (wide) Row(GlanceModifier.fillMaxWidth().height(36.dp).clickable(tap), verticalAlignment = Alignment.CenterVertically) {
        UT(r.at, 11.sp, if (r.live) W1.accent else W1.text, bold = true, modifier = GlanceModifier.width(134.dp))
        Column(GlanceModifier.defaultWeight()) {
            UT(r.name, 13.sp)
            Label(r.line)
        }
        if (r.joined) { Spacer(GlanceModifier.width(8.dp)); Label("In", W1.accent) }
    } else Column(GlanceModifier.fillMaxWidth().height(50.dp).clickable(tap)) {
        Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            UT(r.at, 11.sp, if (r.live) W1.accent else W1.text, bold = true, modifier = GlanceModifier.defaultWeight())
            if (r.joined) Label("In", W1.accent)
        }
        UT(r.name, 12.sp)
        Label(r.line)
    }
}

/** A widget's settings: any of the formats, and Near me or Everywhere (iOS's Edit Widget). */
class UpcomingWidgetConfigActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val widgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        val start = UpcomingEvents.picks(this, widgetId)
        val hasPlace = UpcomingPlace.load(this) != null
        setContent {
            Table1Theme {
                UpcomingSettings(start, hasPlace, onBack = ::finish) { picks ->
                    UpcomingEvents.savePicks(this, widgetId, picks)
                    Telemetry.capture("widget_configured", mapOf("widget" to "upcoming", "formats" to picks.formats.size, "where" to if (picks.near) "near" else "everywhere"))
                    UpcomingEvents.refresh(applicationContext)
                    setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
                    finish()
                }
            }
        }
    }
}

@Composable
internal fun UpcomingSettings(start: UpcomingPicks, hasPlace: Boolean, onBack: () -> Unit, onSave: (UpcomingPicks) -> Unit) {
    var picks by remember { mutableStateOf(start) }
    @Composable fun Picked(on: Boolean) { if (on) UiLabel("Picked", color = T1.accent) }
    androidx.compose.foundation.layout.Column(Modifier.fillMaxSize().background(T1.bg).systemBarsPadding()) {
        Bar("Upcoming events", onBack = onBack)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item { Section("Where") }
            item { ListRow("Near me", if (hasPlace) "Within ${UpcomingWidgets.KM} km" else "Everywhere until the app knows a place", onClick = { picks = picks.copy(near = true) }) { Picked(picks.near) } }
            item { ListRow("Everywhere", onClick = { picks = picks.copy(near = false) }) { Picked(!picks.near) } }
            item { Section("Formats · any you pick") }
            item { ListRow("All formats", onClick = { picks = picks.copy(formats = emptyList()) }) { Picked(picks.formats.isEmpty()) } }
            items(Leagues.formatKeys, key = { "format-${it.first}" }) { (k, label) ->
                ListRow(label, onClick = {
                    val set = if (k in picks.formats) picks.formats - k else picks.formats + k
                    picks = picks.copy(formats = Leagues.formatKeys.map { it.first }.filter { it in set })
                }) { Picked(k in picks.formats) }
            }
        }
        BigAction("Save", accent = false) { onSave(picks) }
    }
}
