package site.table1.events.widgets

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import androidx.glance.appwidget.updateAll
import androidx.glance.text.FontFamily
import androidx.glance.text.FontWeight
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import site.table1.events.MainActivity
import site.table1.events.T1App
import site.table1.events.data.HomeData
import site.table1.events.data.LiveStateResponse
import site.table1.events.data.NextEventData
import site.table1.events.data.NextEventItem
import site.table1.events.data.Repo
import site.table1.events.data.ValueHistory
import site.table1.events.data.ValueRecord
import site.table1.events.library.LibrarySummary

/**
 * The home screen widgets' data (contract/widgets-2026-10-22.md), kept on the device: the app writes it whenever it
 * reads the same things (Events home, the Library summary, live state), and a widget fetches for itself only when its
 * copy is stale (Next event 15 min, Collection value 6 h, Current match 5 min), with an 8 s limit. Same as iOS's App
 * Group stores (NextEventStore, ValueStore, LiveStore).
 */
object Widgets {
    private const val PREFS = "t1.widgets"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ── Next event ──

    fun next(context: Context): NextEventData? =
        prefs(context).getString("next", null)?.let { runCatching { json.decodeFromString<NextEventData>(it) }.getOrNull() }

    /** The Events tab loaded: the widget shows the same, redrawn only when what it shows changed. */
    fun saveNext(context: Context, home: HomeData) {
        val new = NextEventData(home.events.map(NextEventItem::of), home.invites.size, System.currentTimeMillis())
        val old = next(context)
        prefs(context).edit().putString("next", json.encodeToString(NextEventData.serializer(), new)).apply()
        if (old?.events != new.events || old.invites != new.invites) scope.launch { NextEventWidget().updateAll(context) }
    }

    suspend fun nextFresh(context: Context): NextEventData? {
        val held = next(context)
        if (held != null && System.currentTimeMillis() - held.fetchedAt < 15 * 60_000) return held
        if (!signedIn()) return held
        val home = withTimeoutOrNull(8_000) { runCatching { Repo.eventsHome() }.getOrNull() } ?: return held
        val new = NextEventData(home.events.map(NextEventItem::of), home.invites.size, System.currentTimeMillis())
        prefs(context).edit().putString("next", json.encodeToString(NextEventData.serializer(), new)).apply()
        return new
    }

    // ── Collection value ──

    fun value(context: Context): ValueRecord? =
        prefs(context).getString("value", null)?.let { runCatching { json.decodeFromString<ValueRecord>(it) }.getOrNull() }

    /** A Library summary seen (the app's sync or the widget's own fetch): today's point. */
    fun noteValue(context: Context, s: LibrarySummary, fetched: Boolean = false) {
        val user = Repo.userId ?: return
        val old = value(context)
        val r = ValueHistory.record(old, user, s.valueUsd, s.uniqueCards, s.totalQty)
            .let { if (fetched) it.copy(fetchedAt = System.currentTimeMillis()) else it.copy(fetchedAt = old?.takeIf { o -> o.userId == user }?.fetchedAt ?: 0) }
        prefs(context).edit().putString("value", json.encodeToString(ValueRecord.serializer(), r)).apply()
        if (old?.points != r.points || old.cards != r.cards) scope.launch { ValueWidget().updateAll(context) }
    }

    suspend fun valueFresh(context: Context): ValueRecord? {
        val held = value(context)
        if (held != null && System.currentTimeMillis() - held.fetchedAt < 6 * 3600_000L) return held
        if (!signedIn()) return held
        val s = withTimeoutOrNull(8_000) {
            runCatching { T1App.supabase.postgrest.rpc("library_summary_get").decodeAs<LibrarySummary>() }.getOrNull()
        } ?: return held
        noteValue(context, s, fetched = true)
        return value(context)
    }

    // ── Current match (live-activity state) ──

    fun live(context: Context): Pair<LiveStateResponse, Long>? {
        val p = prefs(context)
        val raw = p.getString("live", null) ?: return null
        return runCatching { json.decodeFromString<LiveStateResponse>(raw) }.getOrNull()?.let { it to p.getLong("liveAt", 0) }
    }

    fun saveLive(context: Context, r: LiveStateResponse) {
        prefs(context).edit().putString("live", json.encodeToString(LiveStateResponse.serializer(), r))
            .putLong("liveAt", System.currentTimeMillis()).apply()
    }

    suspend fun liveFresh(context: Context): LiveStateResponse? {
        val held = live(context)
        if (held != null && System.currentTimeMillis() - held.second < 5 * 60_000) return held.first
        if (!signedIn()) return held?.first
        return withTimeoutOrNull(8_000) { Repo.liveState() } ?: held?.first
    }

    fun updateMatch(context: Context) { scope.launch { MatchWidget().updateAll(context) } }

    /** Signed out: the old account's numbers go, and the widgets say so. */
    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
        scope.launch {
            NextEventWidget().updateAll(context); ValueWidget().updateAll(context); MatchWidget().updateAll(context)
        }
    }

    private suspend fun signedIn(): Boolean {
        // A widget can run before the app has read its saved session.
        withTimeoutOrNull(3_000) { runCatching { T1App.supabase.auth.awaitInitialization() } }
        return T1App.supabase.auth.sessionStatus.value is SessionStatus.Authenticated
    }

    /** A tap: the app at a table1:// address (MainActivity reads these, as iOS does). */
    fun open(context: Context, url: String): Intent = Intent(context, MainActivity::class.java)
        .setData(Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
}

/** Table 1's look in a widget: dark, monospace, one teal accent. */
internal object W1 {
    val bg = Color(0xFF171725)
    val surface = Color(0xFF282839)
    val text = Color(0xFFFFFFFF)
    val muted = Color(0xFFC4C4CA)
    val accent = Color(0xFF00FFD9)
    val danger = Color(0xFFFF6B6B)

    fun style(size: TextUnit = 13.sp, color: Color = text, bold: Boolean = false) =
        TextStyle(color = ColorProvider(color), fontSize = size, fontFamily = FontFamily.Monospace,
            fontWeight = if (bold) FontWeight.Bold else FontWeight.Normal)

    /** Uppercase labels with wide tracking, as in the app (Glance has no letter spacing). */
    fun label(color: Color = muted) = style(10.sp, color, bold = false)
}
