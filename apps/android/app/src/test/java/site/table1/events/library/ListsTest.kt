package site.table1.events.library

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ListsTest {
    private val bolt = "f29ba16f-c8fb-42fe-aabf-87089cb214a7"
    private val delver = "11bf83bb-c95b-4b4f-9a56-ce7a1816307a"
    private val json = Json { ignoreUnknownKeys = true }

    // The shape list_edit / lists_changes return (2026-10-15 dry run on the live database).
    private val wire = """{"id":"d1","kind":"deck","name":"Burn","format":"modern","seq":4,"current_version":2,"deleted":false,
      "versions":[{"version":1,"note":"Imported","at":1760000000,"entries":[["$bolt","main",4]]},
                  {"version":2,"note":"Edited","at":1760086400.5,"entries":[["$bolt","main",3],["$delver","maybe",2]]}]}"""

    @Test fun readsAListWithVersions() {
        val l = json.decodeFromString<ListWire>(wire).toList()!!
        assertEquals(2, l.versions.size)
        assertEquals(2, l.current.number)
        assertEquals(3, l.count("main"))
        assertEquals(listOf("main", "maybe"), l.boards)
        assertEquals("Considering", l.boardTitle("maybe"))
    }

    @Test fun deletedListIsGone() {
        assertNull(json.decodeFromString<ListWire>("""{"id":"d1","deleted":true,"seq":9}""").toList())
    }

    @Test fun diffListsRemovalsFirstPerSection() {
        val l = json.decodeFromString<ListWire>(wire).toList()!!
        assertEquals(listOf(ListChange(bolt, "main", -1), ListChange(delver, "maybe", 2)), CardList.diff(l.versions[0], l.versions[1]))
    }

    @Test fun consideringNeverCountsAsMissing() {
        val l = json.decodeFromString<ListWire>(wire).toList()!!
        assertEquals(2, l.missing(mapOf(ownKey(bolt, "nonfoil") to 1)))
        assertEquals(0, l.missing(mapOf(ownKey(bolt, "nonfoil") to 3)))
    }

    @Test fun cacheRoundTrips() {
        val l = json.decodeFromString<ListWire>(wire).toList()!!
        assertEquals(l, ListWire.of(l).toList())
    }

    @Test fun splitsFinishesIntoTheirOwnLines() {
        val l = CardList("x", ListKind.Deck, "x", "modern", listOf(ListVersion(1, 0.0, "Created",
            listOf(ListEntry(bolt, "main", 2), ListEntry(bolt, "main", 2, "foil")))))
        assertEquals(2, l.missing(mapOf(ownKey(bolt, "nonfoil") to 4)))
        assertEquals(0, l.missing(mapOf(ownKey(bolt, "nonfoil") to 2, ownKey(bolt, "foil") to 2)))
        val wire = ListWire.of(l).versions[0].entries.map { it.size }
        assertEquals(listOf(3, 4), wire)
        assertEquals(l, ListWire.of(l).toList())
    }
}
