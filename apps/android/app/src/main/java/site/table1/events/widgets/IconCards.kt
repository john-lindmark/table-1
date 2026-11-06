package site.table1.events.widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.width
import androidx.glance.layout.height
import androidx.glance.unit.ColorProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import site.table1.events.R
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.theme.T1
import site.table1.events.ui.theme.Table1Theme
import site.table1.events.util.Telemetry
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/* The card icon widget (contract/icon-widget-2026-11-06.md): the Table 1 mark over a card's art, like the app icon with a
   card behind it. Cards are picked on a card's page (details → Icon widget) and kept on this device, newest first, with
   their art saved beside them (iOS keeps the same in its App Group); each widget shows the one picked in its settings,
   else the newest. Pure parts are checked against testdata/icon-widget/cases.json in IconCardsTest. */

@Serializable
data class IconCard(
    /** The printing's Scryfall id: its art crop is the background. */
    val id: String,
    val name: String,
    /** "MH2 #438". */
    val set: String,
)

object IconCards {
    const val LIMIT = 12
    /** The mark's width on the app icon (Figma "App icons" 19726:2784). */
    const val LOGO_SHARE = 479f / 1024f

    /** The card goes first; picking it again moves it up; the oldest past [LIMIT] drop off. */
    fun add(cards: List<IconCard>, card: IconCard): List<IconCard> = (listOf(card) + cards.filter { it.id != card.id }).take(LIMIT)

    fun remove(cards: List<IconCard>, id: String): List<IconCard> = cards.filter { it.id != id }

    /** The card picked in a widget's settings while it's still on the list, else the newest; null → the plain icon. */
    fun shown(cards: List<IconCard>, chosen: String?): IconCard? = chosen?.let { c -> cards.firstOrNull { it.id == c } } ?: cards.firstOrNull()

    fun logoWidth(width: Float): Float = (width * LOGO_SHARE).roundToInt().toFloat()
}

/** The list (its own preferences, so signing out keeps it, as on iOS) and the art (files/widgets/icon/<id>.jpg). */
object IconCardStore {
    private const val PREFS = "t1.iconcards"
    /** Big enough for a 2×2 widget at xxxhdpi; RemoteViews bitmaps share a budget of a few screens. */
    const val MAX_PX = 640
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(IconCard.serializer())
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun dir(context: Context) = File(context.filesDir, "widgets/icon")

    fun load(context: Context): List<IconCard> =
        prefs(context).getString("cards", null)?.let { runCatching { json.decodeFromString(serializer, it) }.getOrNull() } ?: emptyList()

    private fun save(context: Context, cards: List<IconCard>) {
        prefs(context).edit().putString("cards", json.encodeToString(serializer, cards)).apply()
    }

    fun contains(context: Context, id: String) = load(context).any { it.id == id }

    fun art(context: Context, id: String): Bitmap? = File(dir(context), "$id.jpg").takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path) }

    /** Saves the art (already downloaded by the app) and puts the card first. False when the art couldn't be written. */
    fun add(context: Context, card: IconCard, image: Bitmap): Boolean {
        val ok = runCatching {
            dir(context).mkdirs()
            val tmp = File(dir(context), "${card.id}.part")
            tmp.outputStream().use { downsized(image).compress(Bitmap.CompressFormat.JPEG, 85, it) }
            tmp.renameTo(File(dir(context), "${card.id}.jpg"))
        }.getOrDefault(false)
        if (!ok) return false
        val before = load(context)
        val after = IconCards.add(before, card)
        before.filter { b -> after.none { it.id == b.id } }.forEach { File(dir(context), "${it.id}.jpg").delete() }
        save(context, after)
        refresh(context)
        return true
    }

    fun remove(context: Context, id: String) {
        save(context, IconCards.remove(load(context), id))
        File(dir(context), "$id.jpg").delete()
        refresh(context)
    }

    // ── per widget: the card picked in its settings ──

    fun chosen(context: Context, widgetId: Int): String? = prefs(context).getString("pick.$widgetId", null)

    fun choose(context: Context, widgetId: Int, id: String?) {
        prefs(context).edit().apply { if (id == null) remove("pick.$widgetId") else putString("pick.$widgetId", id) }.apply()
    }

    fun forget(context: Context, widgetIds: IntArray) {
        prefs(context).edit().apply { widgetIds.forEach { remove("pick.$it") } }.apply()
    }

    fun refresh(context: Context) = Widgets.refresh(context, IconWidget(), IconWidgetReceiver::class.java)

    private fun downsized(b: Bitmap): Bitmap {
        val side = max(b.width, b.height)
        if (side <= MAX_PX) return b
        val k = MAX_PX.toFloat() / side
        return Bitmap.createScaledBitmap(b, (b.width * k).roundToInt(), (b.height * k).roundToInt(), true)
    }
}

/** What a tap does: open the app as its launcher icon does, back where you left it. */
internal fun launchApp(context: Context): Intent =
    (context.packageManager.getLaunchIntentForPackage(context.packageName) ?: Intent(context, site.table1.events.MainActivity::class.java))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)

class IconWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val widgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
        val card = IconCards.shown(IconCardStore.load(context), IconCardStore.chosen(context, widgetId))
        val art = withContext(Dispatchers.IO) { card?.let { IconCardStore.art(context, it.id) } }
        provideContent { IconContent(art, LocalSize.current, actionStartActivity(launchApp(context))) }
    }
}

/** The face: the art under the 60% scrim (Crop, so any shape the widget is resized to is filled) with the mark centered
 *  at the app icon's size, on the shorter side; with no card or its art missing, the plain icon. */
@androidx.compose.runtime.Composable
internal fun IconContent(art: Bitmap?, size: DpSize, tap: Action) {
    val side = min(size.width.value, size.height.value)
    val logo = IconCards.logoWidth(side)
    androidx.glance.layout.Box(GlanceModifier.fillMaxSize().appWidgetBackground().background(W1.bg).cornerRadius(R.dimen.widget_radius).clickable(tap)) {
        if (art != null) {
            Image(ImageProvider(art), contentDescription = null, modifier = GlanceModifier.fillMaxSize(),
                contentScale = androidx.glance.layout.ContentScale.Crop)
            androidx.glance.layout.Box(GlanceModifier.fillMaxSize().background(ColorProvider(W1.bg.copy(alpha = 0.6f)))) {}
        }
        androidx.glance.layout.Box(GlanceModifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Image(ImageProvider(R.drawable.ic_t1_mark), contentDescription = "Table 1",
                modifier = GlanceModifier.width(logo.dp).height((logo * 428f / 863f).dp))
        }
    }
}

class IconWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = IconWidget()

    /** A removed widget's pick goes with it. */
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        IconCardStore.forget(context, appWidgetIds)
    }
}

/** A card icon widget's settings: Newest, or one of the icon cards (iOS's Edit Widget). */
class IconWidgetConfigActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val widgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        val cards = IconCardStore.load(this)
        val chosen = IconCardStore.chosen(this, widgetId)?.takeIf { c -> cards.any { it.id == c } }
        setContent {
            Table1Theme {
                IconSettings(cards, chosen, onBack = ::finish) { pick ->
                    IconCardStore.choose(this, widgetId, pick)
                    Telemetry.capture("widget_configured", mapOf("widget" to "icon", "newest" to (pick == null), "cards" to cards.size))
                    IconCardStore.refresh(applicationContext)
                    setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
                    finish()
                }
            }
        }
    }
}

@Composable
private fun IconSettings(cards: List<IconCard>, chosen: String?, onBack: () -> Unit, onPick: (String?) -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    Column(Modifier.fillMaxSize().background(T1.bg).systemBarsPadding()) {
        Bar("Card icon", onBack = onBack)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item {
                ListRow("Newest", cards.firstOrNull()?.name ?: "Add cards from a card's page", onClick = { onPick(null) }) {
                    if (chosen == null) Label("Picked", color = T1.accent)
                }
            }
            items(cards, key = { it.id }) { c ->
                val art = remember(c.id) { IconCardStore.art(context, c.id)?.asImageBitmap() }
                ListRow(c.name, c.set, onClick = { onPick(c.id) }, avatar = { Thumb(art, 40.dp) }) {
                    if (chosen == c.id) Label("Picked", color = T1.accent)
                }
            }
        }
    }
}

@Composable
private fun Thumb(art: androidx.compose.ui.graphics.ImageBitmap?, side: Dp) {
    Box(Modifier.size(side).background(T1.surface)) {
        art?.let { Image(it, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
    }
}
