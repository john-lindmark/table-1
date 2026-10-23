package site.table1.events.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Play's install referrer → the event address (InstallReferrer.kt), against testdata/app-handoff/cases.json. */
class InstallReferrerTest {
    @Serializable private data class Case(val raw: String, val want: String? = null)
    @Serializable private data class Cases(val referrer: List<Case>)

    private val cases = Json { ignoreUnknownKeys = true }.decodeFromString<Cases>(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/app-handoff") }
            .first { it.isDirectory }, "cases.json").readText(),
    ).referrer

    @Test fun sharedCases() {
        assertTrue(cases.size > 5)
        for (c in cases) assertEquals(c.raw, c.want, InstallReferrer.eventUrl(c.raw))
    }

    /** What it opens is a link the app already routes: the event on the Events tab. */
    @Test fun opensTheEvent() {
        val url = InstallReferrer.eventUrl("t1=%2Fp%2FE1")
        assertEquals("event", WebLink.parse(url)?.kind)
    }
}
