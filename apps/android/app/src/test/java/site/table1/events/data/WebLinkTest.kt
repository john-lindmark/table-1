package site.table1.events.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Universal links (WebLink.kt) against the shared cases in testdata/universal-links/cases.json. */
class WebLinkTest {
    @Serializable private data class Case(val url: String, val to: String? = null)
    @Serializable private data class Cases(val cases: List<Case>)

    private val cases = Json { ignoreUnknownKeys = true }.decodeFromString<Cases>(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/universal-links") }
            .first { it.isDirectory }, "cases.json").readText(),
    ).cases

    @Test fun sharedCases() {
        assertTrue(cases.size > 50)
        for (c in cases) assertEquals(c.url, c.to, WebLink.parse(c.url)?.let(::describe))
    }

    /** The cases' neutral form: "tab > screen arg > screen arg". */
    private fun describe(link: WebLink): String = when (link) {
        WebLink.SignIn -> "auth"
        is WebLink.JoinQr -> "join-qr ${link.link.code} ${link.link.secret}"
        is WebLink.JoinCode -> "join-code ${link.code}"
        is WebLink.Standings -> "standings ${link.eventId}"
        is WebLink.Shared -> "shared ${link.token}"
        is WebLink.Tracker -> listOfNotNull("tracker", link.matchId).joinToString(" ")
        WebLink.Web -> "web"
        is WebLink.Screens -> (listOf(link.tab) + link.stack.map(::screen)).joinToString(" > ")
    }

    private val screens = listOf(
        "event/(\\w+)" to "event $1", "add/(\\w+)" to "add-players $1",
        "collection/all" to "all-cards", "collection/add" to "add", "collection/card/(\\w+)" to "card $1",
        "collection/decks" to "decks", "collection/cubes" to "cubes", "collection/find" to "find-deck", "collection/csv" to "import",
        "collection/import/(\\w+)" to "import-list $1",
        "collection/list/(\\w+)" to "list $1", "collection/list/(\\w+)/add" to "list-add $1", "collection/list/(\\w+)/stats" to "stats $1",
        "collection/list/(\\w+)/stats/(hand|odds|pack)" to "$2 $1", "collection/list/(\\w+)/versions" to "versions $1",
        "collection/list/(\\w+)/v/(\\d+)" to "version $1 $2", "collection/list/(\\w+)/rankings" to "rankings $1",
        "collection/rankings" to "rankings", "collection/ranking/(\\w+)" to "ranking $1",
        "collection/ranking/(\\w+)/screen/(\\w)" to "ranking-pick $1 $2", "collection/ranking/(\\w+)/lists/(\\w)" to "ranking-lists $1 $2",
        "collection/ranking/(\\w+)/card/(\\w+)/(\\w)" to "ranking-card $1 $2 $3",
        "collection/ranking/(\\w+)/compare/(\\w+)/(\\w)" to "ranking-compare $1 $2 $3",
        "collection/ranking/(\\w+)/(pack|changes)" to "ranking-$2 $1",
        "collection/trades" to "trades", "collection/trade/(\\w+)" to "trade $1", "collection/binders" to "binders",
        "collection/binder/(\\w+)" to "binder $1", "collection/wants" to "wants", "collection/matches" to "matches",
        "collection/match/(\\w+)" to "match $1", "friends" to "friends", "sharing" to "sharing", "profile/(\\w+)" to "profile $1",
    ).map { (re, out) -> Regex("^$re$") to out }

    private fun screen(route: String): String =
        screens.firstNotNullOfOrNull { (re, out) -> re.find(route)?.let { m -> re.replace(m.value, out) } } ?: route
}

/* The app's own table1:// addresses (contract/widgets-2026-10-22.md): widgets, the live notification, tiles, shortcuts. */
class AppLinkTest {
    @org.junit.Test fun appAddresses() {
        org.junit.Assert.assertEquals(WebLink.Screens("events", listOf("event/e1")) to "widget_next", WebLink.parseApp("table1://event/e1?src=widget_next"))
        org.junit.Assert.assertEquals(WebLink.Screens("events", emptyList()) to null, WebLink.parseApp("table1://events"))
        org.junit.Assert.assertEquals(WebLink.Screens("collection", emptyList()) to "widget_value", WebLink.parseApp("table1://collection?src=widget_value"))
        org.junit.Assert.assertEquals(WebLink.Tracker(null) to "tile", WebLink.parseApp("table1://tracker?src=tile"))
        org.junit.Assert.assertEquals(WebLink.Screens("collection", listOf("collection/add/scan")) to "shortcut", WebLink.parseApp("table1://scan?src=shortcut"))
        org.junit.Assert.assertNull(WebLink.parseApp("table1://auth-callback#access_token=x"))
        org.junit.Assert.assertNull(WebLink.parseApp("https://table-1.site/e/e1"))
        org.junit.Assert.assertNull(WebLink.parseApp("table1://event"))
    }
}
