package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/*
 * Performance budgets for the scanner on the real catalog pack, same as iOS ScannerPerfTests.swift: building the
 * scanner's name index and matching one camera frame's OCR lines. Runs on the JVM (testDebugUnitTest), so the
 * numbers are a regression signal, not phone timings. Budgets sit ~3x above what John's Mac measured on 2026-10-16.
 */
private object Budget {
    const val NAME_INDEX_MS = 2_500.0
    const val MATCH_MEAN_MS = 2.0
    const val MATCH_P95_MS = 8.0
}

class ScannerPerfTest {
    @Test
    fun matcherPerFrame() {
        val catalog = PackCatalog(String(CatalogPack.gunzip(File(root, "catalog.tsv.gz").readBytes())))
        val t0 = System.nanoTime()
        val names = ScanNames(catalog)
        val indexMs = (System.nanoTime() - t0) / 1e6

        val ocr = Json.parseToJsonElement(File(root, "ocr.json").readText()).jsonObject
        val frames = ocr.values.flatMap { modes -> modes.jsonObject.values.map { v -> v.jsonArray.map { it.jsonPrimitive.content } } }
        assertTrue("OCR fixture loaded", frames.size > 500)
        val matcher = CardMatcher(catalog, null, names)
        repeat(3) { for (f in frames.take(50)) matcher.match(f) } // JIT warm-up
        val times = frames.map { lines ->
            val s = System.nanoTime()
            matcher.match(lines)
            (System.nanoTime() - s) / 1e6
        }.sorted()
        val mean = times.average()
        val p95 = times[(times.size * 0.95).toInt()]
        println("perf android name index: ${indexMs.toInt()} ms (budget ${Budget.NAME_INDEX_MS.toInt()})")
        println("perf android matcher: ${times.size} frames, mean ${"%.2f".format(mean)} ms, p95 ${"%.2f".format(p95)} ms (budget mean ${Budget.MATCH_MEAN_MS}, p95 ${Budget.MATCH_P95_MS})")
        assertTrue("scanner name index ${indexMs.toInt()} ms", indexMs < Budget.NAME_INDEX_MS)
        assertTrue("matcher mean per frame ${"%.2f".format(mean)} ms", mean < Budget.MATCH_MEAN_MS)
        assertTrue("matcher p95 per frame ${"%.2f".format(p95)} ms", p95 < Budget.MATCH_P95_MS)
    }
}
