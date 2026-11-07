package site.table1.events.library

/**
 * How the scanner sets up the back camera (2026-11-07). The guide is 72% of the view's width; at 1× a card fills it
 * about 9 cm from the lens, which is at or inside most main cameras' minimum focus distance (8–15 cm), so a card held
 * to fill the outline was often out of focus. iOS switches to the ultra wide up close (its virtual device); CameraX
 * gives no such switch, so Android zooms the main camera a little and the card is held farther away, in focus.
 * The crop comes from the full sensor, so the 1280×960 frames carry more of the card's detail, not less.
 */
object ScanCamera {
    /**
     * The zoom asked for: a card fills the guide at about 15 cm. Kept under 2× because logical multi-cameras with a
     * 2× telephoto (OnePlus 11 and others) switch to it at 2×, and a telephoto can't focus closer than ~30 cm.
     */
    const val ZOOM = 1.6f

    /** Exposure is metered on this much of the frame around the guide's center (the card, not the table around it). */
    const val METERING_SIZE = 0.3f

    /** The zoom ratio to set, within what the camera allows; null when it can't zoom (leave it at 1×). */
    fun zoom(min: Float, max: Float): Float? {
        if (max < 1.05f || max < min) return null
        return ZOOM.coerceIn(maxOf(min, 1f), max)
    }

    /** How far from the lens a card fills the guide at [zoom], in cm, for a camera whose shorter side sees [fovDeg]°. */
    fun fillDistanceCm(zoom: Float, fovDeg: Float = 51f, guideShare: Float = 0.72f): Float {
        val halfWidth = 6.3f / guideShare / 2 // the frame's width at the card, cm
        return halfWidth / Math.tan(Math.toRadians(fovDeg / 2.0)).toFloat() * zoom
    }
}
