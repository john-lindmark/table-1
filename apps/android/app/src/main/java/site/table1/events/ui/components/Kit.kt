package site.table1.events.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import kotlinx.coroutines.delay
import site.table1.events.ui.theme.T1

/** Full-bleed column; blocks are separated by 1px of background (the hairline grid). */
@Composable
fun T1Screen(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().background(T1.bg).safeDrawingPadding(),
        verticalArrangement = Arrangement.spacedBy(1.dp),
        content = content,
    )
}

@Composable
fun Label(text: String, modifier: Modifier = Modifier, color: Color = T1.muted) {
    Text(
        text.uppercase(),
        modifier = modifier,
        color = color,
        fontFamily = T1.mono,
        fontSize = 11.sp,
        letterSpacing = 1.5.sp,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
fun Bar(title: String, subtitle: String? = null, onBack: (() -> Unit)? = null, actions: @Composable RowScope.() -> Unit = {}) {
    Row(
        modifier = Modifier.fillMaxWidth().background(T1.surface)
            .padding(start = if (onBack == null) 16.dp else 0.dp, end = 16.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (onBack != null) BackArrowButton(onBack)
        Column(Modifier.weight(1f)) {
            Text(title, color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (subtitle != null) Label(subtitle)
        }
        actions()
    }
}

/** Material "arrow_left_alt" (weight 300) from the Figma Bar (node 95:11022), in an 18 dp box. */
private val BackArrowPath: androidx.compose.ui.graphics.Path by lazy {
    androidx.compose.ui.graphics.vector.PathParser()
        .parsePathString("M7.464 13.2403L3.2235 9L7.464 4.75969L8.25431 5.57306L5.38987 8.4375H14.7765V9.5625H5.38987L8.25431 12.4269L7.464 13.2403Z")
        .toPath()
}

/** The back arrow in a 50 × 50 dp tap area; the arrow sits 16 dp from the screen edge, like the Figma bar. */
@Composable
fun BackArrowButton(onClick: () -> Unit) {
    Box(
        // 50 dp wide like the Figma bar; kept to the bar's text height so the bar doesn't grow.
        Modifier.size(width = 50.dp, height = 40.dp)
            .clickable(onClickLabel = "Back", onClick = onClick)
            .semantics { contentDescription = "Back" },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(18.dp)) {
            val k = size.minDimension / 18f
            scale(k, pivot = androidx.compose.ui.geometry.Offset.Zero) { drawPath(BackArrowPath, T1.text) }
        }
    }
}

@Composable
fun BarAction(text: String, onClick: () -> Unit) {
    Label(text, Modifier.clickable(onClick = onClick).padding(4.dp), color = T1.text)
}

/** The one giant full-width action bar. */
@Composable
fun BigAction(text: String, enabled: Boolean = true, busy: Boolean = false, accent: Boolean = false, onClick: () -> Unit) {
    val on = enabled && !busy
    val bg = when {
        !on -> T1.disabled
        accent -> T1.accent
        else -> T1.text
    }
    Box(
        modifier = Modifier.fillMaxWidth().background(bg).clickable(enabled = on, onClick = onClick).padding(vertical = 26.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            (if (busy) "Working…" else text).uppercase(),
            color = T1.ink,
            fontFamily = T1.mono,
            fontWeight = FontWeight.Bold,
            fontSize = 16.sp,
            letterSpacing = 5.sp,
        )
    }
}

@Composable
fun RowScope.Ghost(text: String, enabled: Boolean = true, accent: Boolean = false, onClick: () -> Unit) {
    Box(
        modifier = Modifier.weight(1f)
            .background(if (accent) T1.accent else T1.surface)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Label(text, color = if (accent) T1.ink else if (enabled) T1.text else T1.disabled)
    }
}

@Composable
fun Notice(text: String, error: Boolean = false) {
    Text(
        text,
        modifier = Modifier.fillMaxWidth()
            .background(if (error) T1.danger.copy(alpha = 0.15f) else T1.surface)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        color = if (error) T1.danger else T1.muted,
        fontFamily = T1.mono,
        fontSize = 12.sp,
        lineHeight = 18.sp,
    )
}

@Composable
fun Section(text: String) {
    Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 8.dp)) { Label(text) }
}

@Composable
fun Field(label: String, value: String, onChange: (String) -> Unit, number: Boolean = false) {
    Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
        Label(label)
        BasicTextField(
            value = value,
            onValueChange = onChange,
            singleLine = true,
            textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 15.sp),
            cursorBrush = SolidColor(T1.accent),
            keyboardOptions = KeyboardOptions(keyboardType = if (number) KeyboardType.Number else KeyboardType.Text),
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        )
    }
}

/** A tappable list row with a title, a quiet line and optional trailing content; `avatar` is a player's tile left of the name. */
@Composable
fun ListRow(
    title: String,
    detail: String? = null,
    onClick: (() -> Unit)? = null,
    avatar: (@Composable () -> Unit)? = null,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier = Modifier.fillMaxWidth().background(T1.surface)
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        avatar?.invoke()
        Column(Modifier.weight(1f)) {
            Text(title, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (detail != null) Label(detail)
        }
        trailing()
    }
}

@Composable
fun BigNumber(text: String, caption: String) {
    Column(
        Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text, color = T1.accent, fontFamily = T1.mono, fontSize = 48.sp, letterSpacing = 4.sp, textAlign = TextAlign.Center)
        Label(caption)
    }
}

fun record(w: Int, l: Int, d: Int) = if (d > 0) "$w-$l-$d" else "$w-$l"

/**
 * The Table 1 mark: eleven tiles on a 6 × 3 grid, scaled from the library's "Table 1 Logo" vector
 * (393 × 192.69). Give it a width; the height follows.
 */
@Composable
fun T1Logo(modifier: Modifier = Modifier, color: Color = T1.text) {
    val tiles = listOf(0 to 0, 1 to 0, 2 to 0, 3 to 0, 4 to 0, 1 to 1, 4 to 1, 1 to 2, 3 to 2, 4 to 2, 5 to 2)
    Canvas(modifier.aspectRatio(393f / 192.69f).semantics { contentDescription = "Table 1" }) {
        val sx = size.width / 393f
        val sy = size.height / 192.69f
        tiles.forEach { (c, r) ->
            drawRect(color, topLeft = Offset(c * 65.8036f * sx, r * 64.8302f * sy), size = Size(63.982f * sx, 63.0294f * sy))
        }
    }
}

/** Counts down to a fixed end time (epoch millis) or shows a paused clock. */
@Composable
fun Countdown(endMillis: Long?, pausedSeconds: Int? = null, size: Int = 56) {
    if (endMillis == null) {
        if (pausedSeconds != null) {
            Text("%02d:%02d".format(pausedSeconds / 60, pausedSeconds % 60), color = T1.muted, fontFamily = T1.mono,
                fontSize = size.sp, letterSpacing = (size / 14).sp)
        }
        return
    }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(endMillis) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1000)
        }
    }
    val left = ((endMillis - now) / 1000).coerceAtLeast(0)
    Text(
        if (left == 0L) "TIME" else "%02d:%02d".format(left / 60, left % 60),
        color = if (left == 0L) T1.danger else T1.text, fontFamily = T1.mono, fontSize = size.sp, letterSpacing = (size / 14).sp,
    )
}

/** Small stacked label + value used in hero cards. */
@Composable
fun RowScope.Stat(label: String, value: String, accent: Boolean = false, end: Boolean = false) {
    Column(Modifier.weight(1f), horizontalAlignment = if (end) Alignment.End else Alignment.Start) {
        Label(label)
        Text(value, color = if (accent) T1.accent else T1.text, fontFamily = T1.mono, fontSize = 17.sp, maxLines = 1,
            overflow = TextOverflow.Ellipsis)
    }
}

/** Postgres timestamps → epoch millis ("2026-10-12T01:47:38.449639+00:00"). */
fun parseInstant(s: String?): Long? = s?.let { runCatching { java.time.OffsetDateTime.parse(it).toInstant().toEpochMilli() }.getOrNull() }

fun shortWhen(s: String?): String? = parseInstant(s)?.let {
    java.time.format.DateTimeFormatter.ofPattern("EEE MMM d, h:mm a")
        .format(java.time.Instant.ofEpochMilli(it).atZone(java.time.ZoneId.systemDefault()))
}

/* ── T1 controls (no Material components; AlertDialog is the one native element we keep) ── */

/** Tab bar glyphs drawn from the same square tiles as the logo. */
@Composable
fun TileGlyph(tiles: List<Pair<Int, Int>>, color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.size(20.dp)) {
        val cell = size.width / 2f
        val gap = 2.dp.toPx()
        tiles.forEach { (c, r) ->
            drawRect(color, topLeft = Offset(c * cell, r * cell), size = Size(cell - gap, cell - gap))
        }
    }
}

data class T1Tab(
    val id: String,
    val label: String,
    val tiles: List<Pair<Int, Int>>,
    val enabled: Boolean = true,
    /** Small note under a disabled tab, e.g. "Soon". */
    val note: String? = null,
)

/** Bottom tabs: selected = text-colored label with an accent glyph; unselected muted; disabled greyed. */
@Composable
fun T1TabBar(tabs: List<T1Tab>, selected: String?, onSelect: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(T1.bg).padding(top = 1.dp).navigationBarsPadding(),
        horizontalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        tabs.forEach { tab ->
            val on = tab.id == selected
            val color = when {
                !tab.enabled -> T1.disabled
                on -> T1.text
                else -> T1.muted
            }
            Column(
                Modifier.weight(1f).background(T1.surface)
                    .let { if (tab.enabled) it.clickable { onSelect(tab.id) } else it }
                    .semantics { contentDescription = tab.label + (tab.note?.let { " ($it)" } ?: "") }
                    .padding(vertical = 10.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                TileGlyph(tab.tiles, if (on) T1.accent else color)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Label(tab.label, color = color)
                    tab.note?.let {
                        Text(it.uppercase(), Modifier.background(T1.bg).padding(horizontal = 3.dp), color = T1.disabled,
                            fontFamily = T1.mono, fontSize = 8.sp, letterSpacing = 1.sp, maxLines = 1)
                    }
                }
            }
        }
    }
}

/** Equal-width segments; the selected one is text-on-light (text background, bg text). */
@Composable
fun T1Segmented(options: List<String>, selected: Int, enabled: Boolean = true, scroll: Boolean = false, onSelect: (Int) -> Unit) {
    @Composable
    fun Option(i: Int, label: String, modifier: Modifier) {
        val on = i == selected
        Box(
            modifier.background(if (on) T1.text else T1.surface)
                .border(1.dp, if (on) T1.text else T1.disabled)
                .clickable(enabled = enabled && !on) { onSelect(i) }
                .padding(vertical = 12.dp, horizontal = if (scroll) 16.dp else 0.dp),
            contentAlignment = Alignment.Center,
        ) { Label(label, color = if (on) T1.bg else if (enabled) T1.text else T1.disabled) }
    }
    if (!scroll) {
        Row(Modifier.fillMaxWidth().background(T1.bg), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            options.forEachIndexed { i, label -> Option(i, label, Modifier.weight(1f)) }
        }
        return
    }
    // One row of whole words, at least an equal share each, scrolling sideways when the labels need more room.
    BoxWithConstraints(Modifier.fillMaxWidth().background(T1.bg)) {
        val share = (maxWidth - 1.dp * (options.size - 1)) / options.size
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            options.forEachIndexed { i, label -> Option(i, label, Modifier.widthIn(min = share)) }
        }
    }
}

/** Square On/Off toggle: accent track with the tile at the end when on. */
@Composable
fun T1Switch(checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Box(
        Modifier.size(width = 48.dp, height = 26.dp)
            .background(if (checked) T1.accent else T1.bg)
            .border(1.dp, if (checked) T1.accent else T1.disabled)
            .clickable(enabled = enabled) { onChange(!checked) }
            .semantics { contentDescription = if (checked) "On" else "Off" }
            .padding(4.dp),
        contentAlignment = if (checked) Alignment.CenterEnd else Alignment.CenterStart,
    ) {
        Box(Modifier.size(18.dp).background(if (checked) T1.ink else T1.muted))
    }
}

/** Small outlined tag; [selected] gets the accent outline. */
@Composable
fun T1Chip(text: String, selected: Boolean = false, color: Color = T1.text, onClick: (() -> Unit)? = null) {
    Box(
        Modifier.background(if (selected) T1.surfaceHover else T1.bg)
            .border(1.dp, if (selected) T1.accent else T1.disabled)
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 10.dp, vertical = 7.dp),
    ) { Text(text, color = color, fontFamily = T1.mono, fontSize = 12.sp, maxLines = 1) }
}

/**
 * Labelled text field on the dark well. [onClick] turns it into a picker (read-only, opens something).
 * [error] shows under the field in the danger color.
 */
@Composable
fun T1TextField(
    value: String,
    onChange: (String) -> Unit,
    label: String? = null,
    placeholder: String? = null,
    keyboardType: KeyboardType = KeyboardType.Text,
    error: String? = null,
    trailing: String? = null,
    onClick: (() -> Unit)? = null,
    /** The keyboard's Search key (a search box: usually picks the top hit). */
    onSubmit: (() -> Unit)? = null,
) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        label?.let { Label(it, color = if (error != null) T1.danger else T1.muted) }
        Row(
            Modifier.fillMaxWidth().background(T1.bg)
                .border(1.dp, if (error != null) T1.danger else T1.disabled)
                .let { if (onClick != null) it.clickable(onClick = onClick) else it }
                .padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.weight(1f)) {
                if (onClick != null) {
                    Text(value.ifEmpty { placeholder ?: "" }, color = if (value.isEmpty()) T1.muted else T1.text,
                        fontFamily = T1.mono, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                } else {
                    if (value.isEmpty() && placeholder != null) Text(placeholder, color = T1.muted, fontFamily = T1.mono, fontSize = 15.sp)
                    BasicTextField(
                        value = value, onValueChange = onChange, singleLine = true,
                        textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 15.sp),
                        cursorBrush = SolidColor(T1.accent),
                        keyboardOptions = KeyboardOptions(keyboardType = keyboardType,
                            imeAction = if (onSubmit != null) androidx.compose.ui.text.input.ImeAction.Search else androidx.compose.ui.text.input.ImeAction.Default),
                        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { onSubmit?.invoke() }),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            trailing?.let { Text(it, Modifier.padding(start = 8.dp), color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp) }
        }
        error?.let { Text(it, color = T1.danger, fontFamily = T1.mono, fontSize = 11.sp) }
    }
}

/** − value + on the dark well. [label] null = just the control. [step] is how far one tap moves. */
@Composable
fun T1Stepper(label: String?, value: Int, range: IntRange, modifier: Modifier = Modifier, step: Int = 1, onChange: (Int) -> Unit) {
    Row(modifier.background(T1.bg).padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (label != null) Text(label, Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, maxLines = 1)
        StepSquare("−", enabled = value > range.first) { onChange((value - step).coerceIn(range)) }
        Text("$value", Modifier.widthIn(min = 56.dp), color = T1.accent, fontFamily = T1.mono, fontSize = 22.sp, textAlign = TextAlign.Center)
        StepSquare("+", enabled = value < range.last) { onChange((value + step).coerceIn(range)) }
    }
}

@Composable
private fun StepSquare(text: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp).background(T1.surface).border(1.dp, T1.disabled).clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(text, color = if (enabled) T1.text else T1.disabled, fontFamily = T1.mono, fontSize = 20.sp) }
}

/** A text action like [BarAction] that can be disabled. */
@Composable
fun T1TextAction(text: String, enabled: Boolean = true, color: Color = T1.text, onClick: () -> Unit) {
    Label(text, Modifier.clickable(enabled = enabled, onClick = onClick).padding(horizontal = 8.dp, vertical = 12.dp),
        color = if (enabled) color else T1.disabled)
}

/* ── overlays ───────────────────────────────────────────────────────────────── */

private object FullWindow : PopupPositionProvider {
    override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize, layoutDirection: LayoutDirection, popupContentSize: IntSize) =
        IntOffset.Zero
}

/** Full-window scrim; tapping outside the content (or Back) dismisses. Content is aligned by the caller. */
@Composable
fun T1Overlay(onDismiss: () -> Unit, content: @Composable BoxScope.() -> Unit) {
    Popup(popupPositionProvider = FullWindow, onDismissRequest = onDismiss, properties = PopupProperties(focusable = true)) {
        Box(Modifier.fillMaxSize()) {
            Box(
                Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.6f))
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
            )
            content()
        }
    }
}

/** Swallows taps so they don't fall through to the scrim. */
@Composable
private fun Modifier.absorbTaps(): Modifier =
    clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}

data class T1MenuItem(
    val label: String,
    val enabled: Boolean = true,
    val selected: Boolean = false,
    val danger: Boolean = false,
    val onClick: () -> Unit,
)

/** Bottom menu: optional title, one row per option (selected in accent), then Cancel. Picking dismisses. */
@Composable
fun T1Menu(title: String? = null, items: List<T1MenuItem>, onDismiss: () -> Unit) {
    T1Overlay(onDismiss) {
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().absorbTaps().background(T1.bg)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            title?.let { Section(it) }
            Column(Modifier.fillMaxWidth().heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(1.dp)) {
                items.forEach { item ->
                    Row(
                        Modifier.fillMaxWidth().background(if (item.selected) T1.surfaceHover else T1.surface)
                            .clickable(enabled = item.enabled) {
                                onDismiss()
                                item.onClick()
                            }
                            .padding(horizontal = 16.dp, vertical = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            item.label, Modifier.weight(1f),
                            color = when {
                                !item.enabled -> T1.disabled
                                item.danger -> T1.danger
                                item.selected -> T1.accent
                                else -> T1.text
                            },
                            fontFamily = T1.mono, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                        if (item.selected) Label("✓", color = T1.accent)
                    }
                }
            }
            Box(
                Modifier.fillMaxWidth().background(T1.surface).clickable(onClick = onDismiss).padding(vertical = 16.dp),
                contentAlignment = Alignment.Center,
            ) { Label("Cancel", color = T1.text) }
        }
    }
}

/** Bottom panel overlay with a title bar (optional action) for longer content such as History. */
@Composable
fun T1Panel(
    title: String,
    onDismiss: () -> Unit,
    action: (@Composable RowScope.() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    T1Overlay(onDismiss) {
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().fillMaxHeight(0.8f).absorbTaps().background(T1.bg)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            Bar(title) {
                action?.invoke(this)
                BarAction("Close", onDismiss)
            }
            content()
        }
    }
}

/** The native AlertDialog (the one platform element we keep), in T1 colors with hard corners. */
@Composable
fun T1AlertDialog(
    title: String,
    onDismiss: () -> Unit,
    confirm: @Composable () -> Unit,
    dismiss: (@Composable () -> Unit)? = null,
    body: (@Composable () -> Unit)? = null,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = T1.surface,
        titleContentColor = T1.text,
        textContentColor = T1.muted,
        shape = RectangleShape,
        title = { Text(title, fontFamily = T1.mono, color = T1.text, fontSize = 17.sp) },
        text = body,
        confirmButton = confirm,
        dismissButton = dismiss,
    )
}
