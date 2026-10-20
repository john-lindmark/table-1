package site.table1.events.library

import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/* Where the scanner looks (contract/library-polish-2026-10-19.md § Scanner reads the guide box): the guide box drawn over
   the camera, and where it lands in the camera image, so cards lying around the one being scanned are never read. Same
   rules as iOS `ScanRegion`, but in the image's own coordinates (origin top-left, as ML Kit reports them). */

/** A plain rect (android.graphics.RectF is a stub in unit tests). */
data class Box(val x: Float, val y: Float, val w: Float, val h: Float) {
    val midX get() = x + w / 2
    val midY get() = y + h / 2
    fun contains(px: Float, py: Float) = px >= x && px <= x + w && py >= y && py <= y + h
}

object ScanRegion {
    /** The guide box in the camera view: 72% of the width (or what the height less `margin` allows), card-shaped,
     *  centred. */
    fun viewBox(width: Float, height: Float, margin: Float = 0f): Box {
        val w = max(0f, min(width * 0.72f, (height - margin) * CARD_ASPECT))
        val h = w / CARD_ASPECT
        return Box((width - w) / 2, (height - h) / 2, w, h)
    }

    /** A rect in the preview (which fills the view with the upright image, cropping the overflow) in the image's
     *  normalized coordinates (0…1, origin top-left). */
    fun normalized(r: Box, viewW: Float, viewH: Float, imageW: Float, imageH: Float): Box {
        val s = max(viewW / imageW, viewH / imageH)
        val ox = (viewW - imageW * s) / 2
        val oy = (viewH - imageH * s) / 2
        return Box((r.x - ox) / s / imageW, (r.y - oy) / s / imageH, r.w / s / imageW, r.h / s / imageH)
    }

    fun grown(r: Box, f: Float) = Box(r.x - r.w * f / 2, r.y - r.h * f / 2, r.w * (1 + f), r.h * (1 + f))

    /** Of card-shaped quads (normalized corners), the one to read: its centre inside the guide grown by a quarter (a card
     *  held a little off still counts), nearest the guide's centre in pixels. Null when none is in the guide. */
    fun pick(quads: List<List<Pair<Float, Float>>>, guide: Box, imageW: Float, imageH: Float): Int? {
        val zone = grown(guide, 0.25f)
        fun centre(q: List<Pair<Float, Float>>) = q.sumOf { it.first.toDouble() }.toFloat() / q.size to q.sumOf { it.second.toDouble() }.toFloat() / q.size
        fun dist(p: Pair<Float, Float>) = hypot((p.first - guide.midX) * imageW, (p.second - guide.midY) * imageH)
        return quads.indices.filter { centre(quads[it]).let { c -> zone.contains(c.first, c.second) } }.minByOrNull { dist(centre(quads[it])) }
    }

    /** With no card found: only text whose centre is inside the guide grown 10% is read. Centres are normalized. */
    fun readsText(guide: Box?, cx: Float, cy: Float): Boolean = guide == null || grown(guide, 0.1f).contains(cx, cy)
}
