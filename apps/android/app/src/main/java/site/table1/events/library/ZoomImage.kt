package site.table1.events.library

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1FullScreenDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Zooming a made picture (deck image, top 100; contract/list-to-collection-2026-10-22.md § Zoom): the picture fits
   the box at scale 1 and zooms to MAX around the fingers; while smaller than the box it stays centered, and once
   larger it can't be dragged past an edge. The same math as the web's lib/zoom.ts (ZoomTest). */
object Zoom {
    const val MAX = 8f
    /** Double-tap from fitted. */
    const val STEP = 3f

    data class Size(val w: Float, val h: Float)
    /** Scale over the fitted size, and the picture's top-left corner in the box. */
    data class View(val s: Float, val x: Float, val y: Float)

    fun fitted(box: Size, img: Size): Size {
        if (img.w <= 0f || img.h <= 0f) return Size(0f, 0f)
        val b = minOf(box.w / img.w, box.h / img.h)
        return Size(img.w * b, img.h * b)
    }

    fun clamp(v: View, box: Size, fit: Size): View {
        val w = fit.w * v.s
        val h = fit.h * v.s
        val x = if (w <= box.w) (box.w - w) / 2 else minOf(0f, maxOf(box.w - w, v.x))
        val y = if (h <= box.h) (box.h - h) / 2 else minOf(0f, maxOf(box.h - h, v.y))
        return View(v.s, x, y)
    }

    fun fitView(box: Size, fit: Size) = clamp(View(1f, 0f, 0f), box, fit)

    /** Scale to `s` (kept in 1…MAX) keeping the picture point under (px, py) where it is. */
    fun zoomTo(v: View, s: Float, px: Float, py: Float, box: Size, fit: Size): View {
        val next = s.coerceIn(1f, MAX)
        val k = next / v.s
        return clamp(View(next, px - (px - v.x) * k, py - (py - v.y) * k), box, fit)
    }

    fun pan(v: View, dx: Float, dy: Float, box: Size, fit: Size) = clamp(View(v.s, v.x + dx, v.y + dy), box, fit)

    fun toggle(v: View, px: Float, py: Float, box: Size, fit: Size) =
        if (v.s > 1.01f) fitView(box, fit) else zoomTo(v, STEP, px, py, box, fit)
}

/** What a long press on a made picture offers (contract/deck-image-2026-10-20.md § Long press): Copy to the system
    clipboard, Save to Photos (MediaStore) and Share (the system share sheet). Copy and Save return what to say. */
class MadeImageActions(val copy: suspend () -> String, val save: suspend () -> String, val share: suspend () -> Unit)

/** The long-press menu; `said` gets Copy's and Save's answer. */
@Composable
internal fun MadeImageMenu(actions: MadeImageActions, screen: String, said: (String) -> Unit, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    fun pick(how: String, run: suspend () -> Unit) {
        Telemetry.capture("image_menu", mapOf("screen" to screen, "how" to how))
        scope.launch { run() }
    }
    T1Menu(null, listOf(
        T1MenuItem("Copy") { pick("copy") { said(actions.copy()) } },
        T1MenuItem("Save to Photos") { pick("photos") { said(actions.save()) } },
        T1MenuItem("Share") { pick("share") { actions.share() } },
    ), onDismiss)
}

/** The preview of a made picture: a tap opens it full screen to zoom, a long press offers Copy, Save to Photos and
    Share, and a row under it says so. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ZoomablePreview(image: Bitmap, title: String, subtitle: String?, screen: String, actions: MadeImageActions) {
    var open by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().combinedClickable(
        onLongClickLabel = "Copy, save or share",
        onLongClick = { menu = true },
        onClick = {
            open = true
            Telemetry.capture("image_zoomed", mapOf("screen" to screen))
        },
    ).semantics { contentDescription = "${listOfNotNull(title, subtitle).joinToString(", ")}. Opens it full screen to zoom" }) {
        Image(image.asImageBitmap(), null, Modifier.fillMaxWidth(), contentScale = ContentScale.FillWidth)
        Label(PREVIEW_HINT, Modifier.fillMaxWidth().padding(top = 1.dp).background(T1.surface).padding(horizontal = 16.dp, vertical = 8.dp))
    }
    if (menu) MadeImageMenu(actions, screen, said = {}) { menu = false }
    if (open) ZoomImageScreen(image, title, subtitle, actions, screen) { open = false }
}

/** The row under a made picture's preview (iOS says the same). */
const val PREVIEW_HINT = "Tap to zoom · hold to copy, save or share"

/** Full screen: pinch to zoom, drag to pan, double-tap toggles 3×, long press for Copy, Save and Share when `actions`
    are given (made pictures; card art has none). */
@Composable
fun ZoomImageScreen(image: Bitmap, title: String, subtitle: String?, actions: MadeImageActions? = null, screen: String = "", onClose: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    var said by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(said) { if (said != null) { delay(3000); said = null } }
    val img = Zoom.Size(image.width.toFloat(), image.height.toFloat())
    var box by remember { mutableStateOf(Zoom.Size(0f, 0f)) }
    var view by remember { mutableStateOf(Zoom.View(1f, 0f, 0f)) }
    val fit = Zoom.fitted(box, img)
    val density = LocalDensity.current
    T1FullScreenDialog(onDismissRequest = onClose) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar(title, subtitle, onBack = onClose)
                Box(
                    Modifier.weight(1f).fillMaxWidth().background(T1.bg)
                        .onSizeChanged {
                            box = Zoom.Size(it.width.toFloat(), it.height.toFloat())
                            view = Zoom.fitView(box, Zoom.fitted(box, img))
                        }
                        .pointerInput(box) {
                            detectTransformGestures { centroid, panBy, zoom, _ ->
                                val f = Zoom.fitted(box, img)
                                view = Zoom.pan(Zoom.zoomTo(view, view.s * zoom, centroid.x, centroid.y, box, f), panBy.x, panBy.y, box, f)
                            }
                        }
                        .pointerInput(box) {
                            detectTapGestures(
                                onDoubleTap = { p -> view = Zoom.toggle(view, p.x, p.y, box, Zoom.fitted(box, img)) },
                                onLongPress = if (actions != null) { _ -> menu = true } else null,
                            )
                        }
                        .semantics { contentDescription = listOfNotNull(title, subtitle).joinToString(", ") },
                    contentAlignment = Alignment.TopStart,
                ) {
                    if (fit.w > 0f) {
                        Image(
                            image.asImageBitmap(), null,
                            Modifier.size(with(density) { fit.w.toDp() }, with(density) { fit.h.toDp() })
                                .graphicsLayer {
                                    transformOrigin = TransformOrigin(0f, 0f)
                                    translationX = view.x
                                    translationY = view.y
                                    scaleX = view.s
                                    scaleY = view.s
                                },
                            contentScale = ContentScale.FillBounds,
                        )
                    }
                }
                Label(said ?: if (view.s > 1.01f) "${(view.s * 100).toInt()}% · drag to look around · double-tap to fit" else "Pinch or double-tap to zoom",
                    Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 8.dp))
            }
        }
        if (menu && actions != null) MadeImageMenu(actions, "${screen}_zoom", said = { said = it }) { menu = false }
    }
}
