package site.table1.events.data

/**
 * A push's data (notify-worker: kind, event_id, ranking_id, follow_kind, item_id, user_id, ...), as the app opens it and
 * files it. The same screens as iOS's PushRoutes.
 * Plain strings, so unit tests run without Android.
 */
/** What a tapped New in Insights push opens (contract/insights-2026-10-24.md § New in Insights). */
data class InsightsPush(val section: String, val key: String, val what: String)

object PushRoutes {
    fun insights(data: Map<String, String>): InsightsPush? {
        if (data["kind"] != "insights.new") return null
        val section = data["insights_section"]?.takeIf { it == "constructed" || it == "limited" } ?: return null
        val key = data["insights_key"]?.takeIf { it.isNotBlank() } ?: return null
        return InsightsPush(section, key, if (data["what"] == "rank") "rank" else "data")
    }

    /** A set's Rankings (contract/cube-rankings-2026-10-21.md § Sets): the subject "set:<KEY>", its colon encoded. */
    fun rankSetRoute(key: String) = "collection/list/set%3A${key.uppercase()}/rankings"

    /** The screen a tapped push opens, through the same path as a tapped table-1.site link. */
    fun link(data: Map<String, String>): WebLink? {
        val kind = data["kind"] ?: return null
        fun id(key: String) = data[key]?.takeIf { it.isNotBlank() }
        fun collection(vararg stack: String) = WebLink.Screens("collection", stack.toList())
        return when {
            // "Add your deck photo" (contract/event-night-2026-10-16.md § 7): the event, then its Deck photos on Take a photo.
            kind == "event.deck_photo" -> id("event_id")?.let { WebLink.Screens("events", listOf("event/$it", "photos/$it?add=true")) }
            kind == "insights.new" -> insights(data)?.let { WebLink.Screens("insights", if (it.what == "rank") listOf(rankSetRoute(it.key)) else emptyList()) }
            kind == "want.price" -> collection("collection/wants")
            // A deck search finished (contract/deck-finder-2026-10-15.md § Jobs): Find a deck on that job.
            kind == "deck.found" -> id("job_id")?.let { collection("collection/decks", "collection/find?job=$it") }
            kind == "trade.wants" -> id("user_id")?.let { collection("collection/matches", "collection/match/$it") }
                ?: collection("collection/matches")
            kind == "follow.updated" -> {
                val k = id("follow_kind"); val item = id("item_id")
                if (k != null && item != null) collection("collection/following", "collection/following/$k/$item")
                else collection("collection/following")
            }
            kind == "ranking.started" -> id("ranking_id")?.let { collection("collection/ranking/$it") }
            kind.startsWith("friend.") -> WebLink.Screens("account", listOf("friends"))
            kind == "moderation.review" -> WebLink.Screens("account", listOf("review"))
            kind.startsWith("moderation.") -> WebLink.Screens("account", listOf("notices"))
            kind == "ops.bug" -> id("bug_id")?.toLongOrNull()?.let { WebLink.Screens("account", listOf("bugs", "bug/$it")) }
                ?: WebLink.Screens("account", listOf("bugs"))
            kind.startsWith("ops.") -> WebLink.Screens("account", listOf("bugs"))
            else -> id("event_id")?.let { WebLink.Screens("events", listOf("event/$it")) }
        }
    }

    /** Notification channels, so each kind can be turned off in Android's settings. */
    enum class Channel(val id: String, val title: String, val description: String, val urgent: Boolean) {
        Events("events", "Events", "Pairings, results to confirm, invitations and sign-ups", true),
        Collection("collection", "Collection", "Decks you follow, trades, price drops, cube rankings and found decks", false),
        Friends("friends", "Friends", "Friend requests", false),
        Account("account", "From Table 1", "About your account", false),
        Insights("insights", "New in Insights", "New formats, sets and Arena cubes in Insights", false),
    }

    fun channel(kind: String): Channel = when {
        kind.startsWith("event.") || kind.startsWith("round.") || kind.startsWith("result.") -> Channel.Events
        kind.startsWith("follow.") || kind.startsWith("trade.") || kind.startsWith("want.") || kind.startsWith("ranking.") || kind.startsWith("deck.") -> Channel.Collection
        kind.startsWith("friend.") -> Channel.Friends
        kind.startsWith("insights.") -> Channel.Insights
        else -> Channel.Account
    }
}
