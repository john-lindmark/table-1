package site.table1.events.widgets

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.os.SystemClock
import android.util.TypedValue
import android.widget.RemoteViews
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.AndroidRemoteViews
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ColumnScope
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.layout.wrapContentHeight
import androidx.glance.layout.wrapContentSize
import androidx.glance.layout.wrapContentWidth
import androidx.glance.text.Text
import site.table1.events.R
import site.table1.events.data.LiveSnapshot
import site.table1.events.data.LiveState
import site.table1.events.data.NextEvent
import site.table1.events.data.NextEventData
import site.table1.events.data.NextEventItem
import site.table1.events.data.ValueRecord
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.util.Locale
import kotlin.math.abs
import kotlin.math.floor

/* What the home screen widgets draw (contract/widgets-2026-10-22.md § Android), on data passed in, so the gallery test
   (WidgetGalleryTest) can draw them on sample data. Same look and copy as iOS's Shared/WidgetViews.swift and
   Table1Widgets/MatchWidget.swift at small (2×2) and medium (4×2); Android widgets resize freely, so each also has a
   one-row strip and a tall layout (three rows and up), narrow or wide. */

/** What a widget is resized to. A strip is one row; tall is three rows and up; wide is four columns and up. */
internal enum class WShape(val wide: Boolean) {
    STRIP(false), WIDE_STRIP(true), SMALL(false), MEDIUM(true), TALL(false), LARGE(true);

    val strip get() = this == STRIP || this == WIDE_STRIP
    val tall get() = this == TALL || this == LARGE

    companion object {
        /** Launcher cells run about 73n − 16 dp (two cells 130, three 203, four 276), larger on most phones. */
        val WIDE = 240.dp
        val SQUARE = 110.dp
        val TALL_FROM = 190.dp

        fun of(size: DpSize): WShape {
            val wide = size.width >= WIDE
            return when {
                size.height < SQUARE -> if (wide) WIDE_STRIP else STRIP
                size.height >= TALL_FROM -> if (wide) LARGE else TALL
                else -> if (wide) MEDIUM else SMALL
            }
        }
    }
}

/** The pure parts of the widget layouts: unit-tested without Android. */
internal object WidgetText {
    /** `$812.40`, and whole dollars from $1,000 (`$4,275`), as iOS. */
    fun money(usd: Double): String = NumberFormat.getCurrencyInstance(Locale.US).apply {
        val whole = usd >= 1000
        minimumFractionDigits = if (whole) 0 else 2
        maximumFractionDigits = if (whole) 0 else 2
    }.format(usd)

    /** `+$87.42 · 7 days` / `−$3.10 · 1 day`; it includes cards added or removed, so it never says "market". */
    fun change(c: Pair<Double, Int>): String =
        (if (c.first >= 0) "+" else "−") + money(abs(c.first)) + " · ${c.second} day${if (c.second == 1) "" else "s"}"

    fun invites(n: Int) = "$n invite${if (n == 1) "" else "s"}"

    fun detail(e: NextEventItem) =
        listOfNotNull(e.venueName, "${e.players} player${if (e.players == 1) "" else "s"}").joinToString(" · ")

    /** The biggest text size (sp, up to [max]) at which [text] fits [width] dp in the monospace face (0.6 em a glyph). */
    fun fit(text: String, width: Dp, max: Float, min: Float = max * 0.6f): Float =
        (width.value / (text.length.coerceAtLeast(1) * 0.6f)).coerceIn(min, max)

    /** How many later events a tall Next event widget lists under the first. */
    fun laterRows(height: Dp, wide: Boolean, invites: Boolean, available: Int): Int {
        // The first event, "Then", a "+N more" line and the invites line, as drawn (WidgetGalleryTest).
        val header = if (wide) 136f else 128f
        val room = height.value - 32f - header - 18f - 18f - (if (invites) 18f else 0f)
        return floor(room / (if (wide) 24f else 38f)).toInt().coerceIn(0, minOf(available, 8))
    }

    /** The result buttons, as iOS's MatchOutcome: mine first. */
    val outcomes = listOf(2 to 0, 2 to 1, 1 to 1, 1 to 2, 0 to 2)
}

// ─────────────────────────────────────────────── building blocks

@Composable
internal fun Label(text: String, color: Color = W1.muted, modifier: GlanceModifier = GlanceModifier.wrapContentWidth()) {
    val rv = RemoteViews(LocalContext.current.packageName, R.layout.widget_label).apply {
        setTextViewText(R.id.label, text.uppercase())
        setTextColor(R.id.label, color.toArgb())
    }
    // An embedded view's box fills its column unless told otherwise.
    AndroidRemoteViews(rv, modifier.wrapContentHeight())
}

@Composable
private fun T(text: String, size: TextUnit = 13.sp, color: Color = W1.text, bold: Boolean = false, lines: Int = 1,
              modifier: GlanceModifier = GlanceModifier) =
    Text(text, modifier, style = W1.style(size, color, bold), maxLines = lines)

@Composable
private fun Gap(h: Dp = 4.dp) = Spacer(GlanceModifier.height(h))

@Composable
private fun HGap(w: Dp) = Spacer(GlanceModifier.width(w))

/** The widget itself: Table 1's dark background, the launcher's corners, one tap target. */
@Composable
internal fun WidgetFrame(shape: WShape, tap: Action, content: @Composable ColumnScope.() -> Unit) {
    val pad = when {
        shape.strip -> GlanceModifier.padding(horizontal = 14.dp, vertical = 8.dp)
        shape == WShape.SMALL -> GlanceModifier.padding(14.dp)
        else -> GlanceModifier.padding(16.dp)
    }
    Column(GlanceModifier.fillMaxSize().appWidgetBackground().background(W1.bg).cornerRadius(R.dimen.widget_radius)
        .clickable(tap).then(pad),
        verticalAlignment = if (shape.strip) Alignment.CenterVertically else Alignment.Top, content = content)
}

/** Nothing to show yet: the accent name on top, a line at the bottom (iOS's empty widgets). */
@Composable
private fun ColumnScope.Empty(shape: WShape, title: String, line: String, under: String?, underColor: Color = W1.muted) {
    if (shape.strip) {
        Label(title, W1.accent)
        Gap(2.dp)
        T(line, 12.sp)
        return
    }
    Label(title, W1.accent)
    Spacer(GlanceModifier.defaultWeight())
    T(line, if (shape.tall) 15.sp else 13.sp, lines = 3)
    under?.let { Gap(); Label(it, underColor) }
}

// ─────────────────────────────────────────────── Next event

@Composable
internal fun NextEventContent(data: NextEventData?, signedIn: Boolean, size: DpSize, open: (NextEventItem?) -> Action,
                              now: Instant = Instant.now()) {
    val shape = WShape.of(size)
    val shown = NextEvent.pick(data?.events.orEmpty())
    val invites = data?.invites ?: 0
    val first = shown.firstOrNull()
    WidgetFrame(shape, open(first)) {
        when {
            first == null && !signedIn -> Empty(shape, "Table 1", "Sign in to see your events", null)
            first == null -> Empty(shape, "Table 1", "No events coming up",
                if (invites > 0) WidgetText.invites(invites) else "Create or join one", if (invites > 0) W1.accent else W1.muted)
            shape == WShape.STRIP -> {
                T(NextEvent.timeText(first, now), 13.sp, if (first.isLive) W1.accent else W1.text, bold = true)
                Gap(2.dp)
                T(first.name, 12.sp)
            }
            shape == WShape.WIDE_STRIP -> Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(GlanceModifier.defaultWeight()) {
                    Label(first.label)
                    Gap(2.dp)
                    T(NextEvent.timeText(first, now), 15.sp, if (first.isLive) W1.accent else W1.text, bold = true)
                }
                HGap(12.dp)
                Column(GlanceModifier.defaultWeight()) {
                    T(first.name, 13.sp)
                    Gap(2.dp)
                    Label(if (invites > 0) WidgetText.invites(invites) else WidgetText.detail(first), if (invites > 0) W1.accent else W1.muted)
                }
            }
            shape == WShape.SMALL -> EventCard(first, invites, now, GlanceModifier.fillMaxSize())
            shape == WShape.MEDIUM -> Row(GlanceModifier.fillMaxSize()) {
                EventCard(first, 0, now, GlanceModifier.defaultWeight().fillMaxHeight())
                HGap(12.dp)
                Box(GlanceModifier.width(1.dp).fillMaxHeight().background(W1.surface)) {}
                HGap(12.dp)
                Column(GlanceModifier.defaultWeight().fillMaxHeight()) {
                    Label("Then")
                    Gap()
                    val then = shown.getOrNull(1)
                    if (then != null) {
                        T(then.name, lines = 2)
                        Gap()
                        Label(NextEvent.timeText(then, now))
                    } else T("Nothing else", color = W1.muted)
                    Spacer(GlanceModifier.defaultWeight())
                    if (invites > 0) Label(WidgetText.invites(invites), W1.accent)
                }
            }
            else -> {
                // Tall: the first event large, then as many later ones as fit, each opening its own event. Grouped:
                // Glance draws at most ten children in a column.
                Column {
                    Label(first.label)
                    Gap()
                    T(NextEvent.timeText(first, now), if (shape.wide) 22.sp else 18.sp, if (first.isLive) W1.accent else W1.text, bold = true)
                    if (first.organizing) { Gap(); Label("Organizing") }
                }
                Gap(8.dp)
                Column {
                    T(first.name, 15.sp, lines = 2)
                    Gap()
                    Label(WidgetText.detail(first))
                }
                Gap(10.dp)
                Box(GlanceModifier.fillMaxWidth().height(1.dp).background(W1.surface)) {}
                Gap(10.dp)
                val later = shown.drop(1)
                val rows = WidgetText.laterRows(size.height, shape.wide, invites > 0, later.size)
                Column(GlanceModifier.fillMaxWidth()) {
                    Label("Then")
                    if (later.isEmpty()) T("Nothing else", color = W1.muted, modifier = GlanceModifier.padding(top = 6.dp))
                    later.take(rows).forEach { e ->
                        val row = GlanceModifier.fillMaxWidth().padding(top = 6.dp).clickable(open(e))
                        if (shape.wide) Row(row, verticalAlignment = Alignment.CenterVertically) {
                            T(e.name, modifier = GlanceModifier.defaultWeight())
                            HGap(8.dp)
                            Label(NextEvent.timeText(e, now))
                        } else Column(row) {
                            T(e.name)
                            Gap(2.dp)
                            Label(NextEvent.timeText(e, now))
                        }
                    }
                    if (later.size > rows && rows > 0) Label("+${later.size - rows} more", modifier = GlanceModifier.wrapContentWidth().padding(top = 6.dp))
                }
                Spacer(GlanceModifier.defaultWeight())
                if (invites > 0) Label(WidgetText.invites(invites), W1.accent)
            }
        }
    }
}

/** iOS's small Next event: format, when, organizing; then the name and where at the bottom. */
@Composable
private fun EventCard(e: NextEventItem, invites: Int, now: Instant, modifier: GlanceModifier) {
    // Grouped: Glance draws at most ten children in a column.
    Column(modifier) {
        Column {
            Label(e.label)
            Gap()
            T(NextEvent.timeText(e, now), 15.sp, if (e.isLive) W1.accent else W1.text, bold = true)
            if (e.organizing) { Gap(); Label("Organizing") }
        }
        Spacer(GlanceModifier.defaultWeight())
        Column {
            T(e.name, lines = 2)
            Gap()
            Label(WidgetText.detail(e))
            if (invites > 0) { Gap(); Label(WidgetText.invites(invites), W1.accent) }
        }
    }
}

// ─────────────────────────────────────────────── Collection value

@Composable
internal fun ValueContent(r: ValueRecord?, signedIn: Boolean, size: DpSize, tap: Action, today: LocalDate = LocalDate.now()) {
    val shape = WShape.of(size)
    val value = r?.current
    WidgetFrame(shape, tap) {
        if (r == null || value == null) {
            Empty(shape, "Collection", if (signedIn) "Open the Collection tab to start" else "Sign in to see your collection", null)
            return@WidgetFrame
        }
        val values = r.points.map { it.usd }
        val change = r.change(today = today)
        val changeText = change?.let(WidgetText::change) ?: "From today"
        val changeColor = when {
            change == null || change.first == 0.0 -> W1.muted
            change.first > 0 -> W1.accent
            else -> W1.danger
        }
        val inner = size.width - (if (shape.strip) 28.dp else 32.dp)
        val money = WidgetText.money(value)
        when (shape) {
            WShape.STRIP -> {
                Label("Collection")
                Gap(2.dp)
                T(money, WidgetText.fit(money, inner, 16f).sp, bold = true)
            }
            WShape.WIDE_STRIP -> Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column {
                    Label("Collection")
                    Gap(2.dp)
                    T(money, 18.sp, bold = true)
                }
                HGap(14.dp)
                Sparkline(values, (inner.value * 0.3f).dp, 26.dp, GlanceModifier.defaultWeight().height(26.dp))
                HGap(14.dp)
                Label(changeText, changeColor)
            }
            WShape.SMALL -> {
                Summary(money, changeText, changeColor, inner, 22f, GlanceModifier.defaultWeight().fillMaxWidth())
                Gap()
                Sparkline(values, inner, 30.dp, GlanceModifier.fillMaxWidth().height(30.dp))
            }
            WShape.MEDIUM -> Row(GlanceModifier.fillMaxSize()) {
                Summary(money, changeText, changeColor, 136.dp, 22f, GlanceModifier.width(136.dp).fillMaxHeight())
                HGap(14.dp)
                Column(GlanceModifier.defaultWeight().fillMaxHeight()) {
                    Sparkline(values, inner - 150.dp, size.height - 54.dp, GlanceModifier.fillMaxWidth().defaultWeight())
                    Gap(6.dp)
                    Counts(r)
                }
            }
            else -> {
                Label("Collection")
                Gap(6.dp)
                T(money, WidgetText.fit(money, inner, if (shape.wide) 34f else 26f).sp, bold = true)
                Gap()
                Label(changeText, changeColor)
                Gap(12.dp)
                Sparkline(values, inner, size.height - 140.dp, GlanceModifier.fillMaxWidth().defaultWeight())
                Gap(8.dp)
                if (shape.wide) Counts(r) else Column { Label("${"%,d".format(r.cards)} cards"); Gap(2.dp); Label("${"%,d".format(r.copies)} copies") }
            }
        }
    }
}

/** iOS's value summary: the name on top, the value and its change at the bottom. */
@Composable
private fun Summary(money: String, change: String, color: Color, width: Dp, max: Float, modifier: GlanceModifier) {
    Column(modifier) {
        Label("Collection")
        Spacer(GlanceModifier.defaultWeight())
        T(money, WidgetText.fit(money, width, max).sp, bold = true)
        Gap()
        Label(change, color)
    }
}

@Composable
private fun Counts(r: ValueRecord) = Row(GlanceModifier.fillMaxWidth()) {
    Label("${"%,d".format(r.cards)} cards")
    Spacer(GlanceModifier.defaultWeight())
    Label("${"%,d".format(r.copies)} copies")
}

/** The 30-day line, drawn as a bitmap at about the size it shows (Glance draws no paths). One point: a hairline. */
@Composable
private fun Sparkline(values: List<Double>, width: Dp, height: Dp, modifier: GlanceModifier) {
    val density = LocalContext.current.resources.displayMetrics.density
    val w = (width.value.coerceAtLeast(40f) * density).toInt()
    val h = (height.value.coerceAtLeast(16f) * density).toInt()
    Image(ImageProvider(sparkline(values, w, h, density)), "Value over 30 days", modifier, contentScale = ContentScale.FillBounds)
}

private fun sparkline(values: List<Double>, w: Int, h: Int, density: Float): Bitmap {
    val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(b)
    if (values.size < 2) {
        canvas.drawRect(0f, h / 2f, w.toFloat(), h / 2f + density, Paint().apply { color = W1.surface.toArgb() })
        return b
    }
    // iOS's scale: a flat week stays a flat line at the bottom, not noise blown up to the full height.
    val lo = values.min(); val hi = values.max()
    val span = maxOf(hi - lo, maxOf(hi * 0.002, 0.01))
    val stroke = 1.5f * density
    val path = Path()
    values.forEachIndexed { i, v ->
        val x = i * (w - stroke) / (values.size - 1) + stroke / 2
        val y = stroke / 2 + (h - stroke) * (1 - ((v - lo) / span).toFloat())
        if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
    }
    canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = W1.accent.toArgb(); style = Paint.Style.STROKE; strokeWidth = stroke; strokeJoin = Paint.Join.ROUND
    })
    return b
}

// ─────────────────────────────────────────────── Current match

@Composable
internal fun MatchContent(snap: LiveSnapshot?, size: DpSize, tap: Action, act: (op: String, my: Int, their: Int) -> Action) {
    val shape = WShape.of(size)
    WidgetFrame(shape, tap) {
        if (snap == null) {
            Empty(shape, "Table 1", "No match right now", "Join an event to see it here")
            return@WidgetFrame
        }
        val s = snap.state
        val where = "${s.roundText} · ${s.tableText}"
        when (shape) {
            WShape.STRIP -> {
                Label(where, W1.accent)
                Gap(2.dp)
                if (s.isPlaying) Clock(s, 20f) else T(s.statusLine, 12.sp)
            }
            WShape.WIDE_STRIP -> Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(GlanceModifier.defaultWeight()) {
                    Label(where, W1.accent)
                    Gap(2.dp)
                    T(if (s.isPlaying) "vs ${s.oppName ?: "—"}" else s.statusLine)
                }
                HGap(10.dp)
                if (s.isPlaying) Clock(s, 24f) else Label("You ${s.myRankText} · ${s.myRecord}", W1.accent)
            }
            WShape.SMALL -> SmallMatch(s, GlanceModifier.fillMaxSize())
            WShape.MEDIUM -> Row(GlanceModifier.fillMaxSize()) {
                SmallMatch(s, GlanceModifier.width(128.dp).fillMaxHeight())
                HGap(12.dp)
                Column(GlanceModifier.defaultWeight().fillMaxHeight()) {
                    Label(snap.eventName)
                    Spacer(GlanceModifier.defaultWeight())
                    if (s.isPlaying) Actions(s, compact = true, columns = 3, act)
                    else T(s.statusLine, 12.sp, W1.muted, lines = 3)
                }
            }
            WShape.TALL -> {
                SmallMatch(s, GlanceModifier.fillMaxWidth().defaultWeight())
                if (s.isPlaying) { Gap(10.dp); Actions(s, compact = true, columns = 3, act, stacked = true) }
            }
            WShape.LARGE -> {
                Row(GlanceModifier.fillMaxWidth()) {
                    Label(snap.eventName, modifier = GlanceModifier.defaultWeight())
                    HGap(8.dp)
                    Label(where, W1.accent)
                }
                Gap(10.dp)
                if (s.isPlaying) {
                    Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                        Box(GlanceModifier.defaultWeight()) { Clock(s, 44f) }
                        HGap(12.dp)
                        Column(horizontalAlignment = Alignment.End) {
                            T("vs ${s.oppName ?: "—"}", 15.sp)
                            Gap()
                            Label("${s.oppRankText} · ${s.oppRecord ?: "0-0"}")
                            Gap(2.dp)
                            Label("You ${s.myRankText} · ${s.myRecord}", if (s.needsMyAnswer) W1.accent else W1.muted)
                        }
                    }
                    Spacer(GlanceModifier.defaultWeight())
                    Label(s.statusLine, if (s.status == "disputed") W1.danger else if (s.needsMyAnswer) W1.accent else W1.muted)
                    Gap(8.dp)
                    if (s.canReportNow || s.needsMyAnswer) Actions(s, compact = false, columns = 5, act)
                } else {
                    Spacer(GlanceModifier.defaultWeight())
                    T(s.statusLine, 15.sp, lines = 3)
                    Gap()
                    Label("You ${s.myRankText} · ${s.myRecord}", W1.accent)
                }
            }
        }
    }
}

/** iOS's small Current match: where, the clock, then the opponent and both records. */
@Composable
private fun SmallMatch(s: LiveState, modifier: GlanceModifier) {
    Column(modifier) {
        Label("${s.roundText} · ${s.tableText}", W1.accent)
        Gap()
        if (s.isPlaying) {
            Clock(s, 26f)
            Spacer(GlanceModifier.defaultWeight())
            T("vs ${s.oppName ?: "—"}")
            Gap()
            Label("${s.oppRankText} · ${s.oppRecord ?: "0-0"}")
            Gap(2.dp)
            Label("You ${s.myRankText} · ${s.myRecord}", if (s.needsMyAnswer) W1.accent else W1.muted)
        } else {
            Spacer(GlanceModifier.defaultWeight())
            T(s.statusLine, lines = 3)
            Gap()
            Label("You ${s.myRankText} · ${s.myRecord}", W1.accent)
        }
    }
}

/** The round clock ticks on the home screen (a Chronometer; Glance has none of its own). Red once time is up. */
@Composable
private fun Clock(s: LiveState, size: Float) {
    val context: Context = LocalContext.current
    val end = s.endsAt
    when {
        s.pausedRemaining != null -> T("%02d:%02d".format(s.pausedRemaining / 60, s.pausedRemaining % 60), size.sp, W1.muted)
        end != null -> {
            val left = (end * 1000).toLong() - System.currentTimeMillis()
            val rv = RemoteViews(context.packageName, R.layout.widget_clock).apply {
                setChronometer(R.id.clock, SystemClock.elapsedRealtime() + left, null, true)
                setChronometerCountDown(R.id.clock, true)
                setTextViewTextSize(R.id.clock, TypedValue.COMPLEX_UNIT_SP, size)
                setTextColor(R.id.clock, (if (left > 0) W1.text else W1.danger).toArgb())
            }
            AndroidRemoteViews(rv, GlanceModifier.wrapContentSize())
        }
        else -> T("--:--", size.sp, W1.muted)
    }
}

/** Result buttons (wins on the accent) or Dispute / Confirm, as iOS's MatchActions. */
@Composable
private fun Actions(s: LiveState, compact: Boolean, columns: Int, act: (String, Int, Int) -> Action, stacked: Boolean = false) {
    val height = if (compact) 28.dp else 34.dp
    val text = if (compact) 12.sp else 14.sp

    @Composable
    fun Button(label: String, accent: Boolean, action: Action, modifier: GlanceModifier) =
        Box(modifier.height(height).background(if (accent) W1.accent else W1.surface).clickable(action),
            contentAlignment = Alignment.Center) {
            T(label, text, if (accent) W1.ink else W1.text, bold = true)
        }

    when {
        s.canReportNow -> Column(GlanceModifier.fillMaxWidth()) {
            WidgetText.outcomes.chunked(columns).forEachIndexed { r, row ->
                if (r > 0) Gap()
                Row(GlanceModifier.fillMaxWidth()) {
                    for (i in 0 until columns) {
                        if (i > 0) HGap(4.dp)
                        val o = row.getOrNull(i)
                        if (o == null) Spacer(GlanceModifier.defaultWeight())
                        else Button("${o.first}-${o.second}", o.first > o.second, act("report", o.first, o.second), GlanceModifier.defaultWeight())
                    }
                }
            }
        }
        // Too narrow for both side by side: Confirm (with the score) above Dispute.
        s.needsMyAnswer && s.matchId != null && stacked -> Column(GlanceModifier.fillMaxWidth()) {
            Button("CONFIRM ${s.scoreText}", true, act("confirm", 0, 0), GlanceModifier.fillMaxWidth())
            Gap()
            Button("DISPUTE", false, act("dispute", 0, 0), GlanceModifier.fillMaxWidth())
        }
        s.needsMyAnswer && s.matchId != null -> Row(GlanceModifier.fillMaxWidth()) {
            Button("DISPUTE", false, act("dispute", 0, 0), GlanceModifier.defaultWeight())
            HGap(4.dp)
            Button("CONFIRM ${s.scoreText}", true, act("confirm", 0, 0), GlanceModifier.defaultWeight())
        }
        else -> Label(s.statusLine, if (s.status == "disputed") W1.danger else W1.muted)
    }
}
