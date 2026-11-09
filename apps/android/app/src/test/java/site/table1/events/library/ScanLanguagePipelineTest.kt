package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Language detection the way the Android camera runs it (testdata/scan/README.md § Language detection, "On a
 * phone"): frames one after another, Latin 150 ms and CJK 500 ms each, and each frame started before the last one's
 * lines were matched, so it's read by the reader in use before that. One ML Kit recognizer per script: the one for
 * a card's own script reads `multi`, the other two read only its Latin text (`accurate`); Latin cards read `multi`
 * in every CJK reader (they read Latin too). Each photo held 4 s from Latin, through the scanner's card gate.
 *
 * Before 2026-11-08 every result counted for the reader in use when it came back, not the one that read it: this
 * took 21 of 63 Chinese, Japanese and Korean cards, in 0.5 s on average, so by what the Latin reader reads (the set
 * code and number) before any CJK reader counted; now 39 of 63 (the README's `multi` number), English unchanged
 * (139 of 148 here: the card gate needs a type line or a set code and number).
 */
class ScanLanguagePipelineTest {
    private val catalog = testPack
    private val names = ScanNames.shared(catalog)
    private val cjk = mapOf("ja" to 0, "zhs" to 1, "zht" to 1, "ko" to 2)

    private class Photo(val id: String, val name: String, val lang: String)
    private fun photos() = File(root, "photos.tsv").readLines().drop(1).filter { it.isNotBlank() }.map { row ->
        val c = row.split('\t'); Photo(c[0], c[1], c[4])
    }

    /** One photo through the pipeline; the card taken and when, or null. */
    private fun hold(p: Photo, latin: List<String>, any: List<String>, credited: Boolean): Pair<ScanMatch, Long>? {
        val matcher = CardMatcher(catalog, null, names)
        val steady = ScanSteadiness()
        val language = ScanLanguage(readers = 3)
        var reading = ScanLanguage.LATIN
        var next = reading
        var t = 0L
        while (t < HOLD_MS) {
            val reader = next
            t += if (reader == ScanLanguage.LATIN) LATIN_MS else CJK_MS
            // The camera hands over the next frame as soon as this one is closed, before the main thread has matched
            // this one's lines: it starts with the reader in use now.
            next = reading
            val lines = when {
                reader == ScanLanguage.LATIN -> latin
                p.lang !in cjk -> any
                cjk[p.lang] == reader -> any
                else -> latin
            }
            val hit = matcher.match(lines)?.takeIf { it.exact || CardMatcher.hasTypeLine(lines) }
            steady.feed(hit, t)?.let { taken -> return hit!!.copy(printing = taken.first, exact = taken.second) to t }
            if (credited) language.feed(matched = hit != null, text = lines.isNotEmpty(), now = t, latin = hit != null && ScanLanguage.latin(hit))
            else language.feed(matched = hit != null, text = lines.isNotEmpty(), now = t, latin = hit != null && ScanLanguage.latin(hit), reader = reader)
            reading = language.mode
        }
        return null
    }

    private fun run(credited: Boolean): Map<String, IntArray> {
        val ocr = Json.parseToJsonElement(File(root, "ocr.json").readText()).jsonObject
        // Per group: photos, named right, wrong, and the sum of times taken.
        val groups = sortedMapOf<String, IntArray>()
        for (p in photos()) {
            val reads = ocr[p.id]?.jsonObject ?: continue
            fun read(mode: String) = reads[mode]?.jsonArray?.map { it.jsonPrimitive.content }
            val latin = read("accurate") ?: continue
            val any = read("multi") ?: continue
            val group = if (p.lang == "en") "English" else if (p.lang in cjk) "Chinese, Japanese, Korean" else "Latin and Cyrillic"
            val g = groups.getOrPut(group) { IntArray(4) }
            g[0]++
            val got = hold(p, latin, any, credited) ?: continue
            if (got.first.oracle.idx == catalog.expected[CardName.norm(p.name)]) { g[1]++; g[3] += got.second.toInt() } else g[2]++
        }
        return groups
    }

    private fun report(title: String, groups: Map<String, IntArray>) = println("$title\n" + groups.entries.joinToString("\n") { (g, n) ->
        "  $g: taken ${n[1]}/${n[0]}, wrong ${n[2]}, mean ${if (n[1] == 0) 0.0 else Math.round(n[3] / 100.0 / n[1]) / 10.0} s"
    })

    @Test fun cjkCardsAreTakenOnAPhone() {
        val now = run(credited = false)
        report("Language detection on a phone (frames start before the last is matched):", now)
        for ((g, n) in now) assertEquals("a wrong card taken, $g", 0, n[2])
        val english = now.getValue("English")
        val cards = now.getValue("Chinese, Japanese, Korean")
        assertTrue("English ${english[1]}/${english[0]}", english[1] >= english[0] * 0.93)
        assertTrue("Chinese, Japanese, Korean ${cards[1]}/${cards[0]}", cards[1] >= cards[0] * 0.6)
    }

    /** The bug, kept as a check that the simulation sees it: results credited to the reader in use when they come back. */
    @Test fun creditingTheReaderInUseLosesCjkCards() {
        val before = run(credited = true)
        report("Credited to the reader in use (before 2026-11-08):", before)
        val cards = before.getValue("Chinese, Japanese, Korean")
        assertTrue("Chinese, Japanese, Korean ${cards[1]}/${cards[0]}", cards[1] < run(credited = false).getValue("Chinese, Japanese, Korean")[1])
    }

    private companion object {
        const val HOLD_MS = 4000L
        const val LATIN_MS = 150L
        const val CJK_MS = 500L
    }
}
