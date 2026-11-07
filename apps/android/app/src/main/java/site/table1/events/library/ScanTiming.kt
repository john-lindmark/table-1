package site.table1.events.library

/**
 * How fast one scanner session ran on this phone, sent as `scanner_timing` when the camera closes
 * (contract/telemetry-2026-10-15.md). Scan reports carry only what was read, never how long it took, so until this
 * (2026-11-06) there was no way to see whether a phone's camera, ML Kit or the matcher was the slow part.
 * OCR times are recorded on the camera executor, match times on the main thread.
 */
class ScanTiming(private val started: Long = System.currentTimeMillis()) {
    private val ocr = ArrayList<Int>()
    private val match = ArrayList<Int>()
    private var failed = 0
    private var dropped = 0
    private var cjk = 0
    private var frameSize: Pair<Int, Int>? = null

    /** One frame through ML Kit: how long it took, whether a CJK recognizer read it, and whether it failed. */
    @Synchronized fun read(ms: Long, cjkReader: Boolean, ok: Boolean, width: Int, height: Int) {
        if (ocr.size < MAX) ocr.add(ms.toInt())
        if (cjkReader) cjk++
        if (!ok) failed++
        frameSize = width to height
    }

    /** One frame's match on the main thread. */
    @Synchronized fun matched(ms: Long) { if (match.size < MAX) match.add(ms.toInt()) }

    /** A frame read while the main thread was still matching the last, so it was dropped. */
    @Synchronized fun drop() { dropped++ }

    /** The event's properties; null when no frame was read (the camera never started). */
    @Synchronized fun summary(now: Long = System.currentTimeMillis()): Map<String, Any>? {
        if (ocr.isEmpty()) return null
        val seconds = (now - started).coerceAtLeast(1) / 1000.0
        return buildMap {
            put("frames", ocr.size)
            put("seconds", Math.round(seconds * 10) / 10.0)
            put("fps", Math.round(ocr.size / seconds * 10) / 10.0)
            put("ocr_p50_ms", pct(ocr, 50))
            put("ocr_p90_ms", pct(ocr, 90))
            put("match_p50_ms", pct(match, 50))
            put("match_p90_ms", pct(match, 90))
            put("dropped", dropped)
            put("failed", failed)
            put("cjk_frames", cjk)
            frameSize?.let { put("width", it.first); put("height", it.second) }
        }
    }

    companion object {
        /** Frames kept for the percentiles (a long session's first ~15 minutes at 10 a second). */
        const val MAX = 10_000

        /** The [p]th percentile by nearest rank; 0 for none. */
        fun pct(values: List<Int>, p: Int): Int {
            if (values.isEmpty()) return 0
            val sorted = values.sorted()
            val rank = Math.ceil(p / 100.0 * sorted.size).toInt().coerceIn(1, sorted.size)
            return sorted[rank - 1]
        }
    }
}
