package site.table1.events.ui.support

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Support (contract/support-2026-11-10.md): the bundled files decode, and search follows
 *  testdata/support-search/cases.json from its Python reference (also iOS SupportTests and web support.test.ts). */
class SupportTest {
    @Serializable private data class Norm(val text: String, val words: List<String>)
    @Serializable private data class Case(val query: String, val words: List<String>, val partial: Boolean, val count: Int, val top: List<String>)
    @Serializable private data class Cases(val stop: List<String>, val limit: Int, val normalize: List<Norm>, val cases: List<Case>)

    private fun repo(path: String) =
        File(generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "testdata/support-search").isDirectory }, path)

    private val content = Support.parse(repo("marketing/bundle/support/faq.json").readText(), repo("marketing/bundle/support/guide.json").readText())
    private val cases = Json { ignoreUnknownKeys = true }.decodeFromString<Cases>(repo("testdata/support-search/cases.json").readText())

    @Test fun sharedRule() {
        assertEquals(cases.stop, Support.STOP.sorted())
        assertEquals(cases.limit, Support.LIMIT)
        for (n in cases.normalize) assertEquals(n.text, n.words, Support.words(n.text))
    }

    @Test fun searchCases() {
        for (c in cases.cases) {
            val (hits, partial) = content.search(c.query)
            assertEquals(c.query, c.words, Support.queryWords(c.query))
            assertEquals(c.query, c.partial, partial)
            assertEquals(c.query, c.count, hits.size)
            assertEquals(c.query, c.top, hits.take(8).map { "${it.doc.kind}:${it.doc.id}:${it.score}" })
        }
    }

    @Test fun guideLinksAndGroups() {
        val sections = content.guide.sections.map { it.id }.toSet()
        for (f in content.faq.faqs) f.guide?.let { assertTrue("${f.id} → $it", it in sections) }
        val grouped = content.groups("scanning").flatMap { it.second }.map { it.id }
        assertEquals(content.guide.entries.filter { it.s == "scanning" }.map { it.id }, grouped)
    }
}
