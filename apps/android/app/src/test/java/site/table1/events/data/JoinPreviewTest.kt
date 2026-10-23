package site.table1.events.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The header over sign-in for a scanned join QR (JoinPreview in Models.kt) against testdata/join-preview/cases.json. */
class JoinPreviewTest {
    @Serializable private data class Want(val title: String, val facts: String)
    @Serializable private data class Case(val name: String, val wire: JoinPreview.Wire, val want: Want? = null)
    @Serializable private data class Cases(val cases: List<Case>)

    private val cases = Json { ignoreUnknownKeys = true }.decodeFromString<Cases>(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/join-preview") }
            .first { it.isDirectory }, "cases.json").readText(),
    ).cases

    @Test fun sharedCases() {
        assertTrue(cases.size > 5)
        for (c in cases) {
            val got = JoinPreview.from(c.wire)
            assertEquals(c.name, c.want?.title, got?.title)
            assertEquals(c.name, c.want?.facts, got?.facts)
        }
    }
}
