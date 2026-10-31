package site.table1.events.library

import kotlinx.coroutines.runBlocking
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
        assertEquals(2, l.missing(Holdings(mapOf(ownKey(bolt, "nonfoil") to 1), emptyMap()), emptySet()))
        assertEquals(0, l.missing(Holdings(mapOf(ownKey(bolt, "nonfoil") to 3), emptyMap()), emptySet()))
    }

    @Test fun cacheRoundTrips() {
        val l = json.decodeFromString<ListWire>(wire).toList()!!
        assertEquals(l, ListWire.of(l).toList())
    }

    @Test fun splitsFinishesIntoTheirOwnLines() {
        val l = CardList("x", ListKind.Deck, "x", "modern", listOf(ListVersion(1, 0.0, "Created",
            listOf(ListEntry(bolt, "main", 2), ListEntry(bolt, "main", 2, "foil")))))
        // Any finish of the card covers a line (contract/owned-by-card-2026-10-31.md).
        assertEquals(0, l.missing(Holdings(mapOf(ownKey(bolt, "nonfoil") to 4), emptyMap()), emptySet()))
        assertEquals(1, l.missing(Holdings(mapOf(ownKey(bolt, "foil") to 3), emptyMap()), emptySet()))
        assertEquals(0, l.missing(Holdings(mapOf(ownKey(bolt, "nonfoil") to 2, ownKey(bolt, "foil") to 2), emptyMap()), emptySet()))
        val wire = ListWire.of(l).versions[0].entries.map { it.size }
        assertEquals(listOf(3, 4), wire)
        assertEquals(l, ListWire.of(l).toList())
    }

    @Test fun languagesAreTheirOwnLines() {
        val l = CardList("x", ListKind.Cube, "x", "vintage", listOf(
            ListVersion(1, 0.0, "Created", listOf(ListEntry(bolt, "main", 2))),
            ListVersion(2, 1.0, "Edited", listOf(ListEntry(bolt, "main", 1), ListEntry(bolt, "main", 1, "nonfoil", "ja"), ListEntry(bolt, "main", 1, "foil", "de")))))
        assertEquals(listOf(3, 5, 5), ListWire.of(l).versions[1].entries.map { it.size })
        assertEquals(l, ListWire.of(l).toList())
        assertEquals(listOf(ListChange(bolt, "main", -1, "nonfoil", "en"), ListChange(bolt, "main", 1, "foil", "de"), ListChange(bolt, "main", 1, "nonfoil", "ja")),
            CardList.diff(l.versions[0], l.versions[1]).sortedBy { it.delta * 10 + if (it.lang == "de") 0 else 1 })
        // Missing counts every language.
        assertEquals(1, l.missing(Holdings(mapOf(ownKey(bolt, "nonfoil") to 2), emptyMap()), emptySet()))
    }

    // A sync once made 50 lists_changes calls back to back whatever the server said (2026-10-30 edge logs: ~100 a minute
    // from every Android launch): `return@repeat` only skipped to the next page.
    @Test fun syncStopsWhenThereIsNoMore() = runBlocking {
        val asked = mutableListOf<Long>()
        val calls = readListPages(7, fetch = { after -> asked += after; ListsPage(emptyList(), 7, false) }) { true }
        assertEquals(1, calls)
        assertEquals(listOf(7L), asked)
    }

    @Test fun syncPagesUntilMoreIsFalse() = runBlocking {
        val pages = mapOf(0L to ListsPage(emptyList(), 100, true), 100L to ListsPage(emptyList(), 200, true),
            200L to ListsPage(emptyList(), 230, false))
        val applied = mutableListOf<Long>()
        val calls = readListPages(0, fetch = { pages.getValue(it) }) { applied += it.next; true }
        assertEquals(3, calls)
        assertEquals(listOf(100L, 200L, 230L), applied)
    }

    @Test fun syncStopsWhenTheCursorDoesNotMove() = runBlocking {
        assertEquals(1, readListPages(5, fetch = { ListsPage(emptyList(), 5, true) }) { true })
    }

    @Test fun syncStopsWhenTheAccountChanges() = runBlocking {
        assertEquals(1, readListPages(0, fetch = { ListsPage(emptyList(), it + 100, true) }) { false })
    }

    @Test fun syncReadsAtMostFiftyPages() = runBlocking {
        assertEquals(50, readListPages(0, fetch = { ListsPage(emptyList(), it + 100, true) }) { true })
    }
}
