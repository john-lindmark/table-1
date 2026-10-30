package site.table1.events.ui

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.data.EventRow
import site.table1.events.ui.screens.RedraftPile
import site.table1.events.ui.screens.canRedraft

/* The redraft pile (contract/event-night-2026-10-16.md § 6): finished set drafts only, and redraft_list's shape. */
class RedraftTest {
    private val json = Json { ignoreUnknownKeys = true }
    private fun event(format: String, status: String, cube: String? = null) =
        json.decodeFromString<EventRow>("""{"id":"e","short_code":"ABCD","name":"n","created_by":"u","status":"$status","format":"draft",
            "format_name":"$format"${cube?.let { ""","cube_name":"$it"""" } ?: ""}}""")

    @Test fun finishedSetDraftsOnly() {
        assertTrue(event("draft", "completed").canRedraft)
        assertTrue(event("team_draft", "archived").canRedraft)
        assertFalse(event("draft", "in_progress").canRedraft)
        assertFalse(event("draft", "completed", cube = "Vintage Cube").canRedraft)
        assertFalse(event("modern", "completed").canRedraft)
    }

    @Test fun pileDecodes() {
        val p = json.decodeFromString<RedraftPile>("""{"count":2,"total_usd":12.5,"cards":[
            {"id":"r1","card_id":"c1","finish":"foil","name":"Ragavan","set":"mh2","cn":"138","usd":10.0,"added_by":"Ana","mine":false},
            {"id":"r2","card_id":"c2","finish":"nonfoil","name":"Opt","set":"dom","cn":"60","usd":null,"added_by":"Me","mine":true}]}""")
        assertEquals(2, p.count)
        assertEquals("Ragavan", p.cards.first().name)
        assertTrue(p.cards[1].mine)
    }
}
