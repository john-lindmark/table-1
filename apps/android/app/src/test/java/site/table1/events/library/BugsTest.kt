package site.table1.events.library

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

/* The bug inbox (contract/bug-pipeline-2026-10-18.md § Inbox): bugs_inbox's shape and how it's split, as iOS BugsTests. */
class BugsTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun inboxSplitsAndLines() {
        val i = json.decodeFromString<BugsInbox>("""{"bugs":[
            {"id":10,"severity":"S4","status":"needs_john","platform":"ios","title":"Hang","events":1,"users":1,"regressed":false,"fix_platforms":[],"shipped":[],"last_note":"Question?","my_notes":0},
            {"id":12,"severity":"S1","status":"open","platform":"server","title":"500","events":14,"users":6,"regressed":true,"fix_platforms":[],"shipped":[],"my_notes":0},
            {"id":9,"severity":"S4","status":"fixed","platform":"ios","title":"GID","events":2,"users":1,"regressed":false,"fixed_at":"2026-10-21T08:10:00Z","fix_platforms":["ios","android"],"shipped":["android"],"my_notes":0},
            {"id":3,"severity":"S4","status":"wontfix","platform":"web","title":"Resize","events":40,"users":9,"regressed":false,"fix_platforms":[],"shipped":[],"my_notes":0}],
            "pending":[{"platform":"ios","fixes":1,"worst":"S4","ids":[9],"due":false}]}""")
        assertEquals(listOf(10L), i.needsYou.map { it.id })
        assertEquals(listOf(12L), i.open.map { it.id })
        assertEquals(listOf(3L), i.closed.map { it.id })
        assertEquals(listOf(9L), i.toShip("ios").map { it.id })
        assertEquals(listOf("ios"), i.bugs.first { it.id == 9L }.waitingToShip)
        assertEquals("S1 · Server · 6 people · 14× · came back", BugWords.line(i.bugs[1]))
        assertEquals("S4 · iOS · 1 person · 2× · ship iOS", BugWords.line(i.bugs[2]))
    }

    @Test fun refusalsInPlainWords() {
        assertEquals("Bugs are only for the people who get bug alerts.", BugWords.words(IllegalStateException("42501: Bug watchers only")))
        assertEquals("Pick a severity first.", BugWords.words(IllegalStateException("Pick a severity before sending it on")))
    }
}
