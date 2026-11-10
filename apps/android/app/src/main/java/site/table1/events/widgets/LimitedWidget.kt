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
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.ColumnScope
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import site.table1.events.R
import site.table1.events.T1App
import site.table1.events.insights.LCard
import site.table1.events.insights.LimitedCards
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label as UiLabel
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Section
import site.table1.events.ui.theme.T1
import site.table1.events.ui.theme.Table1Theme
import site.table1.events.util.Telemetry
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.floor

/* The Limited cards widget (contract/widgets-2026-10-22.md § Limited cards widget): a set's best cards in draft from its
   public Limited pack, cut by the widget's own Set, Sort, Rarity and Color (several of each), set up on
   LimitedWidgetConfigActivity. The order and the numbers are the app's Top cards (LimitedCards.cards / .value). */

/** What a Limited cards widget shows; null [set] = the newest set the device knows. */
@Serializable
data class LimitedPicks(val set: String? = null, val sort: String = "gih", val rarity: List<String> = emptyList(), val color: List<String> = emptyList())

/** The parts of a Limited pack the widget reads. */
@Serializable data class LimitedWidgetPack(val set_code: String, val name: String? = null, val events: Map<String, Event> = emptyMap()) {
    @Serializable data class View(val games: Int = 0, val wr: Double = 0.5, val cards: List<LCard> = emptyList())
    @Serializable data class Event(val groups: Map<String, View> = emptyMap())

    /** Premier draft when the set has it, else the first event the pack carries; all players. */
    val view: View? get() {
        val ev = listOf("PremierDraft", "TradDraft", "PickTwoDraft", "Sealed", "TradSealed").firstOrNull { events.containsKey(it) } ?: events.keys.sorted().firstOrNull()
        return ev?.let { events[it]?.groups?.get("all") }
    }
}

object LimitedWidgets {
    data class Row(val place: Int, val name: String, val col: String, val rarity: String?, val value: String, val vs: String?, val above: Boolean)

    /** The widget's rows: the first [n] for the picks, with the sort's number. */
    fun rows(pack: LimitedWidgetPack, picks: LimitedPicks, n: Int): List<Row> {
        val v = pack.view ?: return emptyList()
        return LimitedCards.cards(v.cards, picks.sort, picks.rarity, picks.color).take(n).mapIndexed { i, c ->
            val (value, vs) = LimitedCards.value(c, picks.sort, v.wr)
            val raw = if (picks.sort == "oh") c.oh else c.gih
            Row(i + 1, c.n, c.col?.takeIf { it.isNotEmpty() } ?: "C", c.r?.take(1)?.uppercase(), value, vs, raw?.let { it >= v.wr } ?: false)
        }
    }

    /** "GIH WR · C · U · WU": the sort, then each filter that isn't Any. */
    fun caption(picks: LimitedPicks): String =
        (listOf(LimitedCards.sorts.firstOrNull { it.first == picks.sort }?.third ?: picks.sort.uppercase()) +
            listOfNotNull(picks.rarity.takeIf { it.isNotEmpty() }?.let(LimitedCards::rarityLabel),
                picks.color.takeIf { it.isNotEmpty() }?.let(LimitedCards::colorLabel))).joinToString(" · ")

    fun link(set: String?, src: String) = "table1://insights/limited${set?.let { "/$it" } ?: ""}?src=$src"

    /** The five colors' pips, as Scryfall's mana symbols draw them; colorless grey. */
    fun pip(c: Char): Color = when (c) {
        'W' -> Color(0xFFF8F6D8); 'U' -> Color(0xFFC1D7E9); 'B' -> Color(0xFFBAB1AB); 'R' -> Color(0xFFE49977); 'G' -> Color(0xFFA3C095)
        else -> Color(0xFFCAC5C0)
    }
}

/**
 * Packs, the set list and each widget's picks on the device. Packs are public: fetched at most every 6 hours with
 * If-None-Match and an 8 s limit into files/widgets/limited-<SET>.json. The sets come from Insights' index: the app
 * keeps them here when it loads Insights, and the settings screen asks for the index itself when signed in.
 */
object LimitedPacks {
    private const val PREFS = "t1.widgets.limited"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private const val BASE = "https://aaozhfcbvqrgkkrihkrd.supabase.co/storage/v1/object/public/catalog/insights/limited/"
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun file(context: Context, set: String) = File(context.filesDir, "widgets/limited-$set.json")

    @Serializable data class SetRow(val key: String, val name: String)
    @Serializable private data class IndexRow(val kind: String, val key: String, val name: String)

    fun decode(raw: String): LimitedWidgetPack? = runCatching { json.decodeFromString<LimitedWidgetPack>(raw) }.getOrNull()

    fun load(context: Context, set: String): LimitedWidgetPack? = file(context, set).takeIf { it.exists() }?.let { decode(it.readText()) }

    /** The held pack, refreshed first when older than [maxAgeMs]; the held one when the network fails. Off the main thread. */
    fun fresh(context: Context, set: String, maxAgeMs: Long = 6 * 3600_000L): LimitedWidgetPack? {
        val p = prefs(context)
        val held = load(context, set)
        if (held != null && System.currentTimeMillis() - p.getLong("at.$set", 0) < maxAgeMs) return held
        return runCatching {
            val c = (URL("$BASE$set.json").openConnection() as HttpURLConnection).apply {
                connectTimeout = 8_000; readTimeout = 8_000
                if (held != null) p.getString("etag.$set", null)?.let { setRequestProperty("If-None-Match", it) }
            }
            try {
                when (c.responseCode) {
                    304 -> { p.edit().putLong("at.$set", System.currentTimeMillis()).apply(); held }
                    200 -> {
                        val raw = c.inputStream.bufferedReader().use { it.readText() }
                        val pack = decode(raw) ?: return@runCatching held
                        file(context, set).apply { parentFile?.mkdirs() }.writeText(raw)
                        p.edit().putLong("at.$set", System.currentTimeMillis()).putString("etag.$set", c.getHeaderField("ETag")).apply()
                        pack
                    }
                    else -> held
                }
            } finally { c.disconnect() }
        }.getOrNull() ?: held
    }

    fun sets(context: Context): List<SetRow> =
        prefs(context).getString("sets", null)?.let { runCatching { json.decodeFromString<List<SetRow>>(it) }.getOrNull() } ?: emptyList()

    fun saveSets(context: Context, sets: List<SetRow>) {
        if (sets.isNotEmpty()) prefs(context).edit().putString("sets", json.encodeToString(kotlinx.serialization.builtins.ListSerializer(SetRow.serializer()), sets)).apply()
    }

    /** The index's Limited sets (signed in), else the held list. */
    suspend fun freshSets(context: Context): List<SetRow> = withContext(Dispatchers.IO) {
        runCatching {
            val raw = T1App.supabase.postgrest.rpc("insights_index").data
            json.decodeFromString<List<IndexRow>>(raw).filter { it.kind == "limited" }.map { SetRow(it.key, it.name) }
        }.getOrNull()?.takeIf { it.isNotEmpty() }?.also { saveSets(context, it) } ?: sets(context)
    }

    fun picks(context: Context, widgetId: Int): LimitedPicks =
        prefs(context).getString("picks.$widgetId", null)?.let { runCatching { json.decodeFromString<LimitedPicks>(it) }.getOrNull() } ?: LimitedPicks()

    fun savePicks(context: Context, widgetId: Int, picks: LimitedPicks) {
        prefs(context).edit().putString("picks.$widgetId", json.encodeToString(LimitedPicks.serializer(), picks)).apply()
    }

    fun forget(context: Context, widgetIds: IntArray) {
        prefs(context).edit().apply { widgetIds.forEach { remove("picks.$it") } }.apply()
    }

    fun refresh(context: Context) = Widgets.refresh(context, LimitedWidget(), LimitedWidgetReceiver::class.java)
}

class LimitedWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val widgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
        val saved = LimitedPacks.picks(context, widgetId)
        val picks = if (saved.set != null) saved else saved.copy(set = LimitedPacks.sets(context).firstOrNull()?.key)
        val pack = picks.set?.let { s -> withContext(Dispatchers.IO) { LimitedPacks.fresh(context, s) } }
        provideContent {
            LimitedContent(pack, picks, LocalSize.current,
                actionStartActivity(Widgets.open(context, LimitedWidgets.link(pack?.set_code ?: picks.set, "widget_limited"))))
        }
    }
}

class LimitedWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = LimitedWidget()
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        LimitedPacks.forget(context, appWidgetIds)
    }
}

@androidx.compose.runtime.Composable
private fun LT(text: String, size: TextUnit = 11.sp, color: Color = W1.text, bold: Boolean = false, lines: Int = 1,
               modifier: GlanceModifier = GlanceModifier, end: Boolean = false) =
    Text(text, modifier, style = W1.style(size, color, bold).copy(textAlign = if (end) TextAlign.End else TextAlign.Start), maxLines = lines)

/** What the widget draws, on a pack passed in so WidgetGalleryTest can draw it. Rows fill the height it's given. */
@androidx.compose.runtime.Composable
internal fun LimitedContent(pack: LimitedWidgetPack?, picks: LimitedPicks, size: DpSize, tap: Action) {
    val shape = WShape.of(size)
    WidgetFrame(shape, tap) {
        if (pack?.view == null) {
            Label("Limited cards", W1.accent)
            if (!shape.strip) Spacer(GlanceModifier.defaultWeight())
            LT(if (picks.set == null) "Open Insights → Limited once, then pick a set in this widget's settings." else "${picks.set} loads when you're online",
                12.sp, lines = 3)
            return@WidgetFrame
        }
        val n = when (shape) {
            WShape.STRIP, WShape.WIDE_STRIP -> 1
            else -> floor((size.height.value - 70f) / 19f).toInt().coerceIn(2, 12)
        }
        val rows = LimitedWidgets.rows(pack, picks, n)
        val narrow = !shape.wide
        Row(GlanceModifier.fillMaxWidth()) {
            Label(pack.set_code, W1.text)
            Spacer(GlanceModifier.defaultWeight())
            // The narrowest strip has room for the set only.
            if (shape != WShape.STRIP) Label(LimitedWidgets.caption(picks))
        }
        Spacer(GlanceModifier.height(6.dp))
        if (rows.isEmpty()) LT("No card matches these filters.", 11.sp, W1.muted, lines = 2)
        // Glance draws at most ten children per column: group the rows.
        rows.chunked(6).forEach { group ->
            androidx.glance.layout.Column(GlanceModifier.fillMaxWidth()) { group.forEach { LimitedRow(it, narrow) } }
        }
        if (!shape.strip) {
            Spacer(GlanceModifier.defaultWeight())
            LT("DATA FROM 17LANDS", 7.sp, W1.muted)
        }
    }
}

@androidx.compose.runtime.Composable
private fun LimitedRow(r: LimitedWidgets.Row, narrow: Boolean) {
    Row(GlanceModifier.fillMaxWidth().height(19.dp), verticalAlignment = Alignment.CenterVertically) {
        if (!narrow) LT("${r.place}", 9.sp, W1.muted, modifier = GlanceModifier.width(16.dp), end = true)
        if (!narrow) Spacer(GlanceModifier.width(5.dp))
        r.col.take(3).forEach { c ->
            Box(GlanceModifier.size(7.dp).cornerRadius(4.dp).background(LimitedWidgets.pip(c))) {}
            Spacer(GlanceModifier.width(2.dp))
        }
        Spacer(GlanceModifier.width(3.dp))
        LT(r.name, if (narrow) 10.sp else 11.sp, modifier = GlanceModifier.defaultWeight())
        if (!narrow) {
            r.rarity?.let { LT(it, 9.sp, W1.muted, modifier = GlanceModifier.width(14.dp), end = true) }
            r.vs?.let { LT(it, 9.sp, if (r.above) W1.text else W1.muted, modifier = GlanceModifier.width(32.dp), end = true) }
        }
        LT(r.value, if (narrow) 10.sp else 11.sp, W1.accent, bold = true, modifier = GlanceModifier.width(if (narrow) 42.dp else 48.dp), end = true)
    }
}

/** A widget's settings: the set, the sort, and any rarities and colors (iOS's Edit Widget). */
class LimitedWidgetConfigActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val widgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        val start = LimitedPacks.picks(this, widgetId)
        setContent {
            Table1Theme {
                LimitedSettings(start, onBack = ::finish) { picks ->
                    LimitedPacks.savePicks(this, widgetId, picks)
                    Telemetry.capture("widget_configured", mapOf("widget" to "limited", "set" to (picks.set ?: ""), "sort" to picks.sort,
                        "rarities" to picks.rarity.size, "colors" to picks.color.size))
                    LimitedPacks.refresh(applicationContext)
                    setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
                    finish()
                }
            }
        }
    }
}

@Composable
private fun LimitedSettings(start: LimitedPicks, onBack: () -> Unit, onSave: (LimitedPicks) -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var picks by remember { mutableStateOf(start) }
    var sets by remember { mutableStateOf(LimitedPacks.sets(context)) }
    LaunchedEffect(Unit) { sets = LimitedPacks.freshSets(context) }
    val set = picks.set ?: sets.firstOrNull()?.key
    @Composable fun Picked(on: Boolean) { if (on) UiLabel("Picked", color = T1.accent) }
    Column(Modifier.fillMaxSize().background(T1.bg).systemBarsPadding()) {
        Bar("Limited cards", onBack = onBack)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item { Section("Set") }
            if (sets.isEmpty()) item { ListRow("Open Insights → Limited in the app once, then come back") }
            items(sets, key = { "set-${it.key}" }) { s -> ListRow(s.key, s.name, onClick = { picks = picks.copy(set = s.key) }) { Picked(s.key == set) } }
            item { Section("Sort") }
            items(LimitedCards.sorts, key = { "sort-${it.first}" }) { (k, label, code) ->
                ListRow(label, code, onClick = { picks = picks.copy(sort = k) }) { Picked(picks.sort == k) }
            }
            item { Section("Rarity · any you pick") }
            items(LimitedCards.rarities, key = { "rarity-${it.first}" }) { (k, label) ->
                ListRow(label, onClick = { picks = picks.copy(rarity = LimitedCards.toggle(picks.rarity, k)) }) {
                    Picked(if (k == LimitedCards.ANY) picks.rarity.isEmpty() else k in picks.rarity)
                }
            }
            item { Section("Color · any you pick") }
            items(LimitedCards.colors, key = { "color-${it.first}" }) { (k, label) ->
                ListRow(label, onClick = { picks = picks.copy(color = LimitedCards.toggle(picks.color, k)) }) {
                    Picked(if (k == LimitedCards.ANY) picks.color.isEmpty() else k in picks.color)
                }
            }
        }
        BigAction("Save", accent = false) { onSave(picks.copy(set = set)) }
    }
}
