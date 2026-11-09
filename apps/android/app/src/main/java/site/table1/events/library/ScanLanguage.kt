package site.table1.events.library

/**
 * Which script the camera reads. Nobody picks a language: it reads like the phone (Latin and Cyrillic, English
 * first) until there's text in view that names no card for a while, then switches to Chinese, Japanese and Korean
 * (iOS: Vision's automatic language detection, one reader; Android: ML Kit's Japanese, Chinese and Korean
 * recognizers, one a frame in turn). It stays on the reader that names cards and goes back after a run of misses.
 * The frames spent finding the script are frames ScanSteadiness sees nothing in, so a switch never takes a card early.
 *
 * Every frame says which reader read it ([feed]'s `reader`). On a phone the camera starts the next frame before the
 * last one's lines have been matched, so the frame after a switch was still read by the old reader: before
 * 2026-11-08 each result counted for the reader in use when it came back, so after the switch to CJK a stale Latin
 * miss moved the scanner on from Japanese, the Japanese read of a Japanese card then "matched" for the Chinese reader,
 * and the right reader got one frame in four, too far apart for ScanSteadiness to take the card (contract
 * trades-2026-10-16.md § Scanning "Reading Chinese, Japanese and Korean").
 */
class ScanLanguage(private val readers: Int) {
    /** -1 reads Latin; 0 until [readers] is the CJK reader in use. */
    var mode = LATIN
        private set
    /** The CJK reader that last named a card: the next switch to CJK starts there (a pile of Korean cards). */
    var last = 0
        private set
    private var missSince: Long? = null
    /** A bit per CJK reader that has missed since this run of misses began. */
    private var missed = 0

    /**
     * Feed every frame: whether its lines named a card ([latin]: in a Latin or Cyrillic script), whether there were
     * any lines at all, and the reader that read it (the one in use when the frame started).
     */
    fun feed(matched: Boolean, text: Boolean, now: Long = System.currentTimeMillis(), latin: Boolean = false, reader: Int = mode) {
        if (matched) {
            missSince = null
            missed = 0
            // The reader that named it is the one to keep. A card named in a Latin or Cyrillic script goes back to the
            // Latin reader at once: the CJK recognizers read Latin too, so a pile of English cards after one gap kept
            // the scanner on the slower Japanese, Chinese and Korean models for the rest of the session (2026-11-06).
            mode = if (reader == LATIN || latin) LATIN else reader.also { last = it }
            return
        }
        // A miss read by a reader no longer in use says nothing about the one in use now.
        if (reader != mode) return
        if (mode == LATIN) {
            if (!text) { missSince = null; return }
            val since = missSince ?: now
            missSince = since
            if (now - since >= DETECT_MS) { mode = last; missSince = now; missed = 0 }
        } else {
            val since = missSince ?: now
            missSince = since
            missed = missed or (1 shl mode)
            // Back once every CJK reader has had a frame and missed, and the run has lasted BACK_MS: CJK frames take
            // half a second or more on a phone, so 1.2 s alone went back before the Korean reader read anything.
            if (missed == (1 shl readers) - 1 && now - since >= BACK_MS) { mode = LATIN; missSince = null; missed = 0 }
            else mode = (mode + 1) % readers
        }
    }

    companion object {
        const val LATIN = -1
        /** Text naming no card for this long switches to CJK reading. */
        const val DETECT_MS = 600L
        /** CJK reading naming no card for this long (and with every reader tried) goes back. */
        const val BACK_MS = 1200L
        /** The CJK readers in turn (ML Kit's Japanese model also reads kanji, so it goes first). */
        val READERS = listOf("ja", "zh", "ko")
        private val CJK = setOf("ja", "ko", "zhs", "zht")

        /** Whether a match was read from Latin-script text: no Chinese, Japanese or Korean in what it says it's in (an
         *  English name says nothing, so it counts as Latin). */
        fun latin(m: ScanMatch): Boolean = m.langs.none { it in CJK }

        /** A reader's name for telemetry: latin, ja, zh or ko. */
        fun name(reader: Int): String = READERS.getOrNull(reader) ?: "latin"
    }
}
