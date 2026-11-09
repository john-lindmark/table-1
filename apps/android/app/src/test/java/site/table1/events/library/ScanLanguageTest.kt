package site.table1.events.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which reader the scanner uses (ScanLanguage) and the per-session timing it reports (ScanTiming). */
class ScanLanguageTest {
    private val oracle = CatalogOracle(0, "o", "Lightning Bolt", "lightning bolt", "Instant", "{R}", 1)
    private val printing = CatalogPrinting("c", 0, 0, "lea", "161", "en", "c", "nonfoil", "1993-08-05", "", 1, "")
    private fun match(vararg langs: String) = ScanMatch(oracle, printing, exact = false, langs = langs.toList())

    /** Text that names no card for 0.6 s switches to CJK; English cards now bring it straight back. */
    @Test fun aPileOfEnglishCardsAfterAGapReadsLatin() {
        val l = ScanLanguage(readers = 3)
        var t = 0L
        // A deck box's text between cards: 0.6 s of text naming nothing.
        while (l.mode == ScanLanguage.LATIN) { l.feed(matched = false, text = true, now = t); t += 200 }
        assertEquals(0, l.mode)
        // The next card is English: one frame names it and the Latin reader is back.
        val m = match()
        l.feed(matched = true, text = true, now = t, latin = ScanLanguage.latin(m))
        assertEquals(ScanLanguage.LATIN, l.mode)
    }

    /** Before 2026-11-06 a match in CJK mode kept it there, whatever script the card was in. */
    @Test fun aJapaneseCardKeepsTheCjkReader() {
        val l = ScanLanguage(readers = 3)
        var t = 0L
        while (l.mode == ScanLanguage.LATIN) { l.feed(matched = false, text = true, now = t); t += 200 }
        val ja = match("ja")
        assertFalse(ScanLanguage.latin(ja))
        repeat(10) { l.feed(matched = true, text = true, now = t, latin = ScanLanguage.latin(ja)); t += 200 }
        assertEquals(0, l.mode)
    }

    private fun toCjk(l: ScanLanguage): Long {
        var t = 0L
        while (l.mode == ScanLanguage.LATIN) { l.feed(matched = false, text = true, now = t, reader = ScanLanguage.LATIN); t += 150 }
        return t
    }

    /** The frame after a switch was read by the old reader: its miss says nothing about the new one (2026-11-08). */
    @Test fun aStaleMissDoesNotMoveTheReaderOn() {
        val l = ScanLanguage(readers = 3)
        val t = toCjk(l)
        assertEquals(0, l.mode)
        l.feed(matched = false, text = true, now = t, reader = ScanLanguage.LATIN)
        assertEquals("still Japanese", 0, l.mode)
    }

    /** The reader that named the card is kept, even when the scanner had moved on to the next one meanwhile. */
    @Test fun theReaderThatNamedTheCardIsKept() {
        val l = ScanLanguage(readers = 3)
        var t = toCjk(l)
        l.feed(matched = false, text = true, now = t, reader = 0); t += 500
        assertEquals(1, l.mode)
        // The Chinese frame was already under way; the Japanese one before it came back first and named a card.
        l.feed(matched = true, text = true, now = t, reader = 0); t += 500
        assertEquals(0, l.mode)
        assertEquals(0, l.last)
    }

    /** CJK frames take half a second on a phone: every reader gets one before going back (1.2 s alone skipped Korean). */
    @Test fun everyReaderReadsBeforeGoingBack() {
        val l = ScanLanguage(readers = 3)
        var t = toCjk(l)
        val read = mutableListOf<Int>()
        while (l.mode != ScanLanguage.LATIN) { read += l.mode; t += 600; l.feed(matched = false, text = true, now = t, reader = l.mode) }
        assertEquals(listOf(0, 1, 2), read)
    }

    /** A pile of Korean cards: after a gap the next switch starts on the Korean reader. */
    @Test fun theLastReaderGoesFirst() {
        val l = ScanLanguage(readers = 3)
        var t = toCjk(l)
        l.feed(matched = false, text = true, now = t, reader = 0); l.feed(matched = false, text = true, now = t, reader = 1)
        l.feed(matched = true, text = true, now = t, reader = 2)
        assertEquals(2, l.mode)
        while (l.mode != ScanLanguage.LATIN) { t += 500; l.feed(matched = false, text = false, now = t, reader = l.mode) }
        while (l.mode == ScanLanguage.LATIN) { t += 150; l.feed(matched = false, text = true, now = t, reader = ScanLanguage.LATIN) }
        assertEquals(2, l.mode)
    }

    @Test fun latinScripts() {
        assertTrue(ScanLanguage.latin(match()))
        assertTrue(ScanLanguage.latin(match("de")))
        assertTrue(ScanLanguage.latin(match("ru")))
        assertFalse(ScanLanguage.latin(match("ko")))
        assertFalse(ScanLanguage.latin(match("zhs", "zht")))
    }

    /** Latin mode is unchanged: a match there is just a match. */
    @Test fun latinMatchInLatinMode() {
        val l = ScanLanguage(readers = 3)
        l.feed(matched = true, text = true, now = 0, latin = true)
        assertEquals(ScanLanguage.LATIN, l.mode)
    }

    @Test fun timingSummary() {
        val t = ScanTiming(started = 0)
        assertNull(t.summary(now = 1000))
        for (ms in listOf(100L, 120L, 140L, 400L)) t.read(ms, reader = ScanLanguage.LATIN, ok = true, width = 1280, height = 960)
        t.read(900, reader = 2, ok = false, width = 1280, height = 960)
        t.matched(2); t.matched(30)
        t.drop()
        t.named(2, false); t.named(ScanLanguage.LATIN, true)
        t.switched(ScanLanguage.LATIN, 0); t.switched(0, 1); t.switched(2, ScanLanguage.LATIN)
        t.models("requested")
        val s = t.summary(now = 2000)!!
        assertEquals(5, s["frames"])
        assertEquals(2.0, s["seconds"])
        assertEquals(2.5, s["fps"])
        assertEquals(140, s["ocr_p50_ms"])
        assertEquals(900, s["ocr_p90_ms"])
        assertEquals(2, s["match_p50_ms"])
        assertEquals(30, s["match_p90_ms"])
        assertEquals(1, s["dropped"])
        assertEquals(1, s["failed"])
        assertEquals(1, s["cjk_frames"])
        assertEquals(1280, s["width"])
        assertEquals(1, s["ko_frames"])
        assertEquals(1, s["ko_failed"])
        assertEquals(0, s["ko_named"])
        assertEquals(0, s["ja_frames"])
        assertEquals(1, s["to_cjk"])
        assertEquals(1, s["to_latin"])
        assertEquals("requested", s["cjk_models"])
    }

    @Test fun percentiles() {
        assertEquals(0, ScanTiming.pct(emptyList(), 50))
        assertEquals(7, ScanTiming.pct(listOf(7), 90))
        assertEquals(5, ScanTiming.pct((1..10).toList(), 50))
        assertEquals(9, ScanTiming.pct((1..10).toList(), 90))
    }
}
