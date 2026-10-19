package site.table1.events.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * event_bundle (contract/privacy-lockdown-2026-10-18.md) decoded from testdata/event-bundle/bundle.json, which
 * testdata/event-bundle/make.sh writes from the real RPC: a server shape change fails here, not in the app.
 */
class EventBundleTest {
    private val json = Json { ignoreUnknownKeys = true }
    private fun fixture(name: String) =
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/event-bundle") }.first { it.isDirectory }, name).readText()

    @Test fun decodesTheServersEventBundle() {
        val b = Repo.bundle(json.decodeFromString<EventBundleWire>(fixture("bundle.json")))
        assertTrue(b.isOrganizer)
        assertEquals("FIXT", b.event.shortCode)
        assertEquals("in_progress", b.event.status)
        assertEquals(listOf("Ana Organizer", "Ben Player", "Guest Cara"), b.participants.map { it.displayName })
        assertNull(b.participants[2].userId)
        assertEquals(listOf(1, 2), b.rounds.map { it.number })
        val played = b.rounds.first().matches.first()
        assertEquals(listOf(2, 1), played.sides.sortedBy { it.side }.map { it.gameWins })
        assertEquals(listOf(true, false), b.rounds.last().matches.map { it.isBye })
    }

    @Test fun teamsComeFromTheBundleInOrder() {
        val wire = json.decodeFromString<EventBundleWire>(fixture("bundle.json"))
            .copy(teams = listOf(BundleTeam("t2", "Second", 2), BundleTeam("t1", "First", 1)))
        assertEquals(listOf("First" to 1, "Second" to 2), Repo.bundle(wire).teams.map { it.name to it.displayOrder })
    }
}
