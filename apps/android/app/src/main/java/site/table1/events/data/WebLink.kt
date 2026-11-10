package site.table1.events.data

import java.net.URI

/**
 * A tapped https://table-1.site link, as the app opens it (contract/universal-links-2026-10-22.md). Every web address
 * with a screen here opens that screen; the rest go back to the browser. Shared cases: testdata/universal-links/cases.json.
 * Plain strings (java.net.URI), so unit tests run without Android.
 */
sealed interface WebLink {
    /** The sign-in email's button; SignIn.emailLinkHash reads the link itself. */
    data object SignIn : WebLink
    data class JoinQr(val link: JoinLink) : WebLink
    data class JoinCode(val code: String) : WebLink
    /** The event if you organize or play in it, else the public standings page in the browser. */
    data class Standings(val eventId: String) : WebLink
    /** A share link's token: the shared part for someone signed in, else the web page (no account needed). */
    data class Shared(val token: String) : WebLink
    /** A tab ("events", "collection", "account") and the nav routes above it, parents first. */
    data class Screens(val tab: String, val stack: List<String>) : WebLink
    data class Tracker(val matchId: String?) : WebLink
    /** An Insights widget's tap: the format on the widget's events and window, then the grid or an archetype's page. */
    /** [set]: the Limited cards widget's set (table1://insights/limited/<SET>); [format] is then "limited", and
     *  [limited] the widget's Sort, Rarity and Color when it sent them. */
    data class Insights(val format: String, val tier: String?, val days: Int?, val stack: List<String>, val set: String? = null,
                        val limited: site.table1.events.widgets.LimitedPicks? = null) : WebLink
    /** table-1.site, but no screen in the app (privacy policy, account deletion, a web sign-in's return): the browser. */
    data object Web : WebLink

    /** Telemetry's `to` (never an id). */
    val kind: String get() = when (this) {
        SignIn -> "sign_in"
        is JoinQr -> "join_qr"
        is JoinCode -> "join_code"
        is Standings -> "standings"
        is Shared -> "shared"
        is Screens -> if (tab == "events" && stack.isNotEmpty()) "event" else tab
        is Tracker -> "tracker"
        is Insights -> "insights"
        Web -> "web"
    }

    companion object {
        val hosts = setOf("table-1.site", "www.table-1.site")
        private val jobs = setOf("W", "U", "B", "R", "G", "M", "C", "L", "F")

        fun standingsUrl(eventId: String) = "https://table-1.site/s/$eventId"
        fun sharedUrl(token: String) = "https://table-1.site/l/$token"

        /**
         * The app's own table1:// addresses (contract/widgets-2026-10-22.md), opened by widgets, the live notification,
         * Quick Settings tiles and launcher shortcuts, as on iOS: `table1://event/<id>`, `table1://events`,
         * `table1://collection`, `table1://tracker`, `table1://scan`. A `src` query names the surface for telemetry.
         * null for anything else (auth-callback is supabase-kt's).
         */
        fun parseApp(raw: String?): Pair<WebLink, String?>? {
            val u = runCatching { URI(raw?.trim() ?: return null) }.getOrNull() ?: return null
            if (u.scheme != "table1") return null
            val src = (u.rawQuery ?: "").split("&").firstOrNull { it.startsWith("src=") }?.substringAfter("=")?.takeIf { it.isNotEmpty() }
            val p = (u.rawPath ?: "").split("/").filter { it.isNotEmpty() }
            val link = when (u.host) {
                "event" -> p.singleOrNull()?.let { Screens("events", listOf("event/$it")) }
                "events", "home" -> Screens("events", emptyList())
                "collection" -> Screens("collection", emptyList())
                "tracker" -> Tracker(null)
                "scan" -> Screens("collection", listOf("collection/add/scan"))
                // Insights widgets: table1://insights/<format>[/matchups | /archetype/<id>]?tier=big&days=30
                "insights" -> p.firstOrNull()?.let { f ->
                    val q = (u.rawQuery ?: "").split("&").associate { it.substringBefore("=") to java.net.URLDecoder.decode(it.substringAfter("=", ""), "UTF-8") }
                    // The Limited cards widget: table1://insights/limited/<SET>[?sort=iwd&rarity=common&color=W,U] (blank = Any).
                    if (f == "limited") return@let p.getOrNull(1)?.takeIf { it.isNotEmpty() }?.let { set ->
                        val picks = q["sort"]?.takeIf { s -> site.table1.events.insights.LimitedCards.sorts.any { it.first == s } }?.let { sort ->
                            fun list(k: String) = (q[k] ?: "").split(",").filter { it.isNotEmpty() }
                            site.table1.events.widgets.LimitedWidgets.picks(set.uppercase(), sort, list("rarity"), list("color"))
                        }
                        Insights("limited", null, null, emptyList(), set.uppercase(), picks)
                    }
                    val stack = when {
                        p.getOrNull(1) == "matchups" -> listOf("insights/matchups/$f")
                        p.getOrNull(1) == "archetype" && p.getOrNull(2)?.toIntOrNull() != null -> listOf("insights/arch/$f/${p[2]}")
                        else -> emptyList()
                    }
                    Insights(f, q["tier"]?.takeIf { it == "big" || it == "all" }, q["days"]?.toIntOrNull()?.takeIf { it in listOf(7, 14, 30, 90) }, stack)
                }
                else -> null
            } ?: return null
            return link to src
        }

        /** null when [raw] isn't a table-1.site link at all. */
        fun parse(raw: String?): WebLink? {
            val u = runCatching { URI(raw?.trim() ?: return null) }.getOrNull() ?: return null
            if (u.scheme != "https" || u.host?.lowercase() !in hosts) return null
            // A web sign-in (Apple/Google) coming back to the page that asked: that session belongs to the browser.
            val fragment = u.rawFragment ?: ""
            if ("access_token=" in fragment || "error_description=" in fragment) return Web
            val query = (u.rawQuery ?: "").split("&").associate { it.substringBefore("=") to it.substringAfter("=", "") }
            if (!query["code"].isNullOrEmpty()) return Web

            val p = (u.rawPath ?: "").split("/").filter { it.isNotEmpty() }
            fun events(vararg stack: String) = Screens("events", stack.toList())
            fun account(vararg stack: String) = Screens("account", stack.toList())
            return when {
                p.isEmpty() || p == listOf("sign-in") -> events()
                p.size == 2 && p[0] == "e" -> events("event/${p[1]}")
                p.size == 3 && p[0] == "e" && p[2] == "add" -> events("event/${p[1]}", "add/${p[1]}")
                p.size == 2 && p[0] == "p" -> events("event/${p[1]}")
                p.size == 2 && p[0] == "s" -> Standings(p[1])
                p.size == 2 && p[0] == "l" -> Shared(p[1])
                p.size == 2 && p[0] == "join" -> JoinCode(p[1])
                p.firstOrNull() == "j" -> JoinLink.parse(raw)?.let { JoinQr(it) } ?: Web
                p == listOf("auth", "confirm") -> SignIn
                p.firstOrNull() == "life" && p.size <= 2 -> Tracker(p.getOrNull(1))
                p.firstOrNull() == "library" -> library(p.drop(1))?.let { Screens("collection", it) } ?: Web
                p == listOf("me") -> account()
                p == listOf("friends") || p == listOf("friends", "add") -> account("friends")
                p == listOf("sharing") -> account("sharing")
                // A profile's section opens the profile: the section's title and deck come from the profile itself.
                p.firstOrNull() == "u" && p.size in 2..4 -> account("profile/${p[1]}")
                else -> Web
            }
        }

        /** The Collection stack under /library, parents first so Back lands where it would on the web. */
        private fun library(p: List<String>): List<String>? {
            val c = "collection"
            return when {
                p.isEmpty() -> emptyList()
                p == listOf("cards") -> listOf("$c/all")
                p == listOf("add") -> listOf("$c/add")
                p.size == 2 && p[0] == "card" -> listOf("$c/card/${p[1]}")
                p == listOf("decks") -> listOf("$c/decks")
                p == listOf("cubes") -> listOf("$c/cubes")
                p == listOf("find") -> listOf("$c/decks", "$c/find")
                p == listOf("import") -> listOf("$c/csv")
                p.size == 2 && p[0] == "import" -> (if (p[1] == "cube") "cube" else "deck").let { listOf("$c/${it}s", "$c/import/$it") }
                p.size >= 2 && p[0] == "list" -> list(p[1], p.drop(2))
                p == listOf("rankings") -> listOf("$c/cubes", "$c/rankings")
                p.size >= 2 && p[0] == "ranking" -> ranking(p[1], p.drop(2))?.let { listOf("$c/ranking/${p[1]}") + it }
                p == listOf("trades") -> listOf("$c/trades")
                p.size == 2 && p[0] == "trade" -> listOf("$c/trades", "$c/trade/${p[1]}")
                p == listOf("binders") -> listOf("$c/binders")
                p.size == 2 && p[0] == "binder" -> listOf("$c/binders", "$c/binder/${p[1]}")
                p == listOf("wants") -> listOf("$c/wants")
                p == listOf("matches") -> listOf("$c/matches")
                p.size == 2 && p[0] == "match" -> listOf("$c/matches", "$c/match/${p[1]}")
                else -> null
            }
        }

        private fun list(id: String, rest: List<String>): List<String>? {
            val l = "collection/list/$id"
            return when (rest) {
                emptyList<String>() -> listOf(l)
                listOf("add") -> listOf(l, "$l/add")
                // Change printing needs the line, which only the deck screen knows.
                listOf("printing") -> listOf(l)
                listOf("stats") -> listOf(l, "$l/stats")
                listOf("stats", "hand"), listOf("stats", "odds"), listOf("stats", "pack") -> listOf(l, "$l/stats", "$l/stats/${rest[1]}")
                listOf("versions") -> listOf(l, "$l/versions")
                listOf("rankings") -> listOf(l, "$l/rankings")
                else -> if (rest.size == 2 && rest[0] == "v" && rest[1].toIntOrNull() != null) listOf(l, "$l/versions", "$l/v/${rest[1]}") else null
            }
        }

        /** The screens above a ranking's overview. */
        private fun ranking(id: String, rest: List<String>): List<String>? {
            val r = "collection/ranking/$id"
            return when {
                rest.isEmpty() -> emptyList()
                rest == listOf("pack") || rest == listOf("changes") -> listOf("$r/${rest[0]}")
                rest.size == 2 && rest[0] in setOf("screen", "lists") && rest[1] in jobs -> listOf("$r/${rest[0]}/${rest[1]}")
                rest.size == 3 && rest[0] in setOf("card", "compare") && rest[2] in jobs -> listOf("$r/${rest[0]}/${rest[1]}/${rest[2]}")
                else -> null
            }
        }
    }
}
