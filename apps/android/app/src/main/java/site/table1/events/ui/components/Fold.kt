package site.table1.events.ui.components

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import site.table1.events.util.Telemetry
import site.table1.events.ui.theme.T1
import kotlin.math.max
import kotlin.math.min

/**
 * Foldables (contract/foldables-2026-11-10.md): one rule for every container, from its own size (dp) and the folds
 * crossing it in its own space. Never the device type or orientation (Android's window size class guidance).
 */
data class Fold(
    val x: Float, val y: Float, val w: Float, val h: Float,
    /** Runs top to bottom (book), else across (tabletop). */
    val vertical: Boolean,
    /** FoldingFeature.isSeparating: half opened, or a dual screen's hinge. */
    val separating: Boolean = true,
    val margin: Float = 0f,
)

data class FoldRect(val x: Float, val y: Float, val w: Float, val h: Float)

enum class FoldMode(val wire: String) { Single("single"), Wide("wide"), Tabletop("tabletop"), Book("book") }

data class FoldLayout(
    val width: String,
    val height: String,
    val mode: FoldMode,
    /** One rect (single) or two (first, second); the fold's band belongs to neither. */
    val panes: List<FoldRect>,
    /** The tab bar runs down the side (a navigation rail). */
    val rail: Boolean,
    /** iOS only (Android turns with the device everywhere): the shorter side is 600+. */
    val rotates: Boolean,
) {
    val twoPanes: Boolean get() = panes.size == 2
    val posture: String get() = if (mode == FoldMode.Tabletop || mode == FoldMode.Book) mode.wire else "flat"
}

object FoldRule {
    const val CLEAR = 8f
    const val MIN_PANE = 120f
    const val WIDE = 840f
    const val HEIGHT_MIN = 480f

    fun widthClass(w: Float) = if (w < 600f) "compact" else if (w < 840f) "medium" else "expanded"
    fun heightClass(h: Float) = if (h < 480f) "compact" else if (h < 900f) "medium" else "expanded"

    fun of(w: Float, h: Float, folds: List<Fold>): FoldLayout {
        var mode = FoldMode.Single
        var panes = listOf(FoldRect(0f, 0f, w, h))
        for (f in folds) {
            if (!f.separating) continue
            val clear = max(CLEAR, f.margin)
            if (f.vertical) {
                val a = f.x - clear
                val b = f.x + f.w + clear
                if (a >= MIN_PANE && w - b >= MIN_PANE) {
                    mode = FoldMode.Book
                    panes = listOf(FoldRect(0f, 0f, a, h), FoldRect(b, 0f, w - b, h))
                    break
                }
            } else {
                val a = f.y - clear
                val b = f.y + f.h + clear
                if (a >= MIN_PANE && h - b >= MIN_PANE) {
                    mode = FoldMode.Tabletop
                    panes = listOf(FoldRect(0f, 0f, w, a), FoldRect(0f, b, w, h - b))
                    break
                }
            }
        }
        if (mode == FoldMode.Single && w >= WIDE && h >= HEIGHT_MIN) {
            val half = (w - 1f) / 2f
            mode = FoldMode.Wide
            panes = listOf(FoldRect(0f, 0f, half, h), FoldRect(half + 1f, 0f, w - half - 1f, h))
        }
        return FoldLayout(widthClass(w), heightClass(h), mode, panes, rail = mode != FoldMode.Tabletop && w > h, rotates = min(w, h) >= 600f)
    }

    /** A FoldingFeature's bounds (window pixels) as a fold in window dp. */
    fun fromBounds(left: Int, top: Int, right: Int, bottom: Int, vertical: Boolean, separating: Boolean, density: Float) =
        Fold(left / density, top / density, (right - left) / density, (bottom - top) / density, vertical, separating)

    fun from(feature: FoldingFeature, density: Float): Fold = feature.bounds.let {
        fromBounds(it.left, it.top, it.right, it.bottom, feature.orientation == FoldingFeature.Orientation.VERTICAL,
            feature.isSeparating, density)
    }

    /** Design QA without a foldable: `--es t1Fold tabletop|book` puts a 20 dp fold across the middle of the window. */
    fun debug(mode: String?, w: Float, h: Float): List<Fold> = when (mode) {
        "tabletop" -> listOf(Fold(0f, h / 2 - 10f, w, 20f, vertical = false))
        "book" -> listOf(Fold(w / 2 - 10f, 0f, 20f, h, vertical = true))
        else -> emptyList()
    }
}

/** Each pane keeps clear of the system bars on its own window edges only: tabletop's top pane the top, its bottom
 *  pane the bottom; book's and wide's left pane the start, the right pane the end. */
@Composable
fun Modifier.paneInsets(mode: FoldMode, first: Boolean): Modifier {
    val sides = if (mode == FoldMode.Tabletop) {
        (if (first) WindowInsetsSides.Top else WindowInsetsSides.Bottom) + WindowInsetsSides.Horizontal
    } else {
        (if (first) WindowInsetsSides.Start else WindowInsetsSides.End) + WindowInsetsSides.Vertical
    }
    return windowInsetsPadding(WindowInsets.safeDrawing.only(sides))
}

/** Set by MainActivity from the `t1Fold` extra in debug builds. */
object FoldDebug { var mode: String? = null }

/** The window's folds (dp, window space) and its layout. */
data class WindowFold(val layout: FoldLayout, val folds: List<Fold>)

val LocalWindowFold = staticCompositionLocalOf { WindowFold(FoldRule.of(411f, 891f, emptyList()), emptyList()) }

/** Around the whole app: reads FoldingFeatures from Jetpack WindowManager and measures the window. */
@Composable
fun ProvideWindowFold(activity: Activity, content: @Composable () -> Unit) {
    val flow = remember(activity) { WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity) }
    val info by flow.collectAsState(initial = null)
    val density = LocalDensity.current.density
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val w = maxWidth.value
        val h = maxHeight.value
        val real = info?.displayFeatures?.filterIsInstance<FoldingFeature>()?.map { FoldRule.from(it, density) }.orEmpty()
        val folds = real.ifEmpty { FoldRule.debug(FoldDebug.mode, w, h) }
        val state = WindowFold(FoldRule.of(w, h, folds), folds)
        val posture = state.layout.posture
        LaunchedEffect(posture) {
            if (posture != "flat") Telemetry.capture("fold_posture",
                mapOf("posture" to posture, "width" to state.layout.width, "height" to state.layout.height))
        }
        CompositionLocalProvider(LocalWindowFold provides state) { content() }
    }
}

/**
 * Two panes when the container is wide or folded into tabletop or book (and the mode is in [allow]); else [single].
 * The panes sit at the rule's rects, so nothing lands on the fold's band.
 */
@Composable
fun FoldSplit(
    screen: String,
    modifier: Modifier = Modifier.fillMaxSize(),
    allow: Set<FoldMode> = setOf(FoldMode.Wide, FoldMode.Tabletop, FoldMode.Book),
    enabled: Boolean = true,
    single: @Composable () -> Unit,
    first: @Composable (FoldLayout) -> Unit,
    second: @Composable (FoldLayout) -> Unit,
) {
    val window = LocalWindowFold.current
    val density = LocalDensity.current.density
    var origin by remember { mutableStateOf(Offset.Zero) }
    BoxWithConstraints(modifier.onGloballyPositioned {
        val p = it.positionInWindow()
        val dp = Offset(p.x / density, p.y / density)
        if (dp != origin) origin = dp
    }) {
        val local = window.folds.map { it.copy(x = it.x - origin.x, y = it.y - origin.y) }
        val layout = FoldRule.of(maxWidth.value, maxHeight.value, local)
        val split = enabled && layout.twoPanes && layout.mode in allow
        val shown = if (split) layout.mode else FoldMode.Single
        LaunchedEffect(shown) {
            if (shown != FoldMode.Single) Telemetry.capture("fold_layout", mapOf("mode" to shown.wire, "screen" to screen))
        }
        if (split) {
            val a = layout.panes[0]
            val b = layout.panes[1]
            Box(Modifier.fillMaxSize().background(T1.bg)) {
                if (layout.mode == FoldMode.Wide) {
                    Box(Modifier.offset(x = a.w.dp).width(1.dp).fillMaxHeight().background(T1.surface))
                }
                Box(Modifier.offset(a.x.dp, a.y.dp).size(a.w.dp, a.h.dp)) { first(layout) }
                Box(Modifier.offset(b.x.dp, b.y.dp).size(b.w.dp, b.h.dp)) { second(layout) }
            }
        } else {
            single()
        }
    }
}
