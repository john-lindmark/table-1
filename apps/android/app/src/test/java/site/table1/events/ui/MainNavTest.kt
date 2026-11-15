package site.table1.events.ui

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/** The tab table and the remembered sub-tab rule (MainNav.kt) against testdata/main-nav/cases.json
 *  (contract/main-nav-2026-11-14.md). */
class MainNavTest {
    @Serializable private data class SubCase(val id: String, val label: String, val web: String, val fullScreen: Boolean = false)
    @Serializable private data class TabCase(val id: String, val label: String, val default: String, val subs: List<SubCase>)
    @Serializable private data class Remembered(val tab: String, val stored: String? = null, val want: String)
    @Serializable private data class Cases(val tabs: List<TabCase>, val remembered: List<Remembered>)

    private val cases = Json { ignoreUnknownKeys = true }.decodeFromString<Cases>(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/main-nav") }
            .first { it.isDirectory }, "cases.json").readText(),
    )

    @Test fun tabsMatchTheSharedTable() {
        assertEquals(cases.tabs.map { it.id }, MainNav.tabs.map { it.id })
        for (want in cases.tabs) {
            val tab = MainNav.tab(want.id)!!
            assertEquals(want.id, want.label, tab.label)
            assertEquals(want.id, want.default, tab.default)
            assertEquals(want.id, want.subs.map { Triple(it.id, it.label, it.fullScreen) }, tab.subs.map { Triple(it.id, it.label, it.fullScreen) })
        }
    }

    @Test fun rememberedFollowsTheSharedCases() {
        for (c in cases.remembered) assertEquals("${c.tab} ${c.stored}", c.want, MainNav.remembered(c.tab, c.stored))
    }

    @Test fun keysAreNavSubPerTab() {
        assertEquals("nav.sub.collection", MainNav.key("collection"))
    }

    /** A link or push through a sub-tab's own screen selects it instead of pushing a copy; deeper screens push. */
    @Test fun linksSelectSubTabRoots() {
        assertEquals(MainNav.Placed("collection", "trade", emptyList()), MainNav.place("collection", listOf("collection/trades")))
        assertEquals(MainNav.Placed("collection", "trade", listOf("collection/trade/t1")),
            MainNav.place("collection", listOf("collection/trades", "collection/trade/t1")))
        assertEquals(MainNav.Placed("collection", "wants", emptyList()), MainNav.place("collection", listOf("collection/wants")))
        // /library/rankings: its cubes parent is dropped, Insights → Rankings selected.
        assertEquals(MainNav.Placed("insights", "rankings", emptyList()), MainNav.place("collection", listOf("collection/cubes", "collection/rankings")))
        val deeper = MainNav.place("collection", listOf("collection/list/abc"))
        assertNull(deeper.sub)
        assertEquals(listOf("collection/list/abc"), deeper.stack)
        // A tab with nothing above it opens on its first sub-tab (`/`, `/library`, `/me`); Insights keeps its section.
        assertEquals("collection", MainNav.place("collection", emptyList()).sub)
        assertEquals("profile", MainNav.place("account", emptyList()).sub)
        assertEquals("events", MainNav.place("events", emptyList()).sub)
        assertNull(MainNav.place("insights", emptyList()).sub)
        // A set's rankings stay a push on the Insights tab.
        assertNull(MainNav.place("insights", listOf("collection/list/set%3AFRA/rankings")).sub)
    }
}
