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
    /** Per CJK reader (ScanLanguage.READERS): frames read, frames that failed (a model not installed yet) and
     *  frames whose lines named a card. */
    private val cjkReads = IntArray(ScanLanguage.READERS.size)
    private val cjkFailed = IntArray(ScanLanguage.READERS.size)
    private val cjkNamed = IntArray(ScanLanguage.READERS.size)
    private var toCjk = 0
    private var toLatin = 0
    private var models: String? = null
    private var frameSize: Pair<Int, Int>? = null
    private var zoom: Float? = null
    private var minFocusCm: Int? = null

    /** One frame through ML Kit: how long it took, which reader read it (ScanLanguage.mode), and whether it failed. */
    @Synchronized fun read(ms: Long, reader: Int, ok: Boolean, width: Int, height: Int) {
        if (ocr.size < MAX) ocr.add(ms.toInt())
        if (reader in cjkReads.indices) { cjk++; cjkReads[reader]++; if (!ok) cjkFailed[reader]++ }
        if (!ok) failed++
        frameSize = width to height
    }

    /** One frame's lines matched: which reader read them and whether they named a card. */
    @Synchronized fun named(reader: Int, named: Boolean) { if (named && reader in cjkNamed.indices) cjkNamed[reader]++ }

    /** The scanner switched reader (ScanLanguage.mode before and after a frame). */
    @Synchronized fun switched(from: Int, to: Int) {
        if (from == to) return
        if (from == ScanLanguage.LATIN) toCjk++ else if (to == ScanLanguage.LATIN) toLatin++
    }

    /** Whether the Japanese, Chinese and Korean models were on the phone when the scanner opened (ScanModels). */
    @Synchronized fun models(state: String) { models = state }

    /** The zoom set on the camera (ScanCamera) and its closest focus in cm, once it's bound. */
    @Synchronized fun camera(zoom: Float, minFocusCm: Int?) { this.zoom = zoom; this.minFocusCm = minFocusCm }

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
            put("to_cjk", toCjk)
            put("to_latin", toLatin)
            ScanLanguage.READERS.forEachIndexed { i, r ->
                put("${r}_frames", cjkReads[i]); put("${r}_failed", cjkFailed[i]); put("${r}_named", cjkNamed[i])
            }
            models?.let { put("cjk_models", it) }
            frameSize?.let { put("width", it.first); put("height", it.second) }
            zoom?.let { put("zoom", Math.round(it * 100) / 100.0) }
            minFocusCm?.let { put("min_focus_cm", it) }
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
