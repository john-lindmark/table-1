package site.table1.events.data

/**
 * A push's data (notify-worker: kind, event_id, ranking_id, follow_kind, item_id, user_id, ...), as the app opens it and
 * files it. The same screens as iOS's PushRoutes; Android has no Notices, Review or Bugs screens, so those open Account.
 * Plain strings, so unit tests run without Android.
 */
object PushRoutes {
    /** The screen a tapped push opens, through the same path as a tapped table-1.site link. */
    fun link(data: Map<String, String>): WebLink? {
        val kind = data["kind"] ?: return null
        fun id(key: String) = data[key]?.takeIf { it.isNotBlank() }
        fun collection(vararg stack: String) = WebLink.Screens("collection", stack.toList())
        return when {
            kind == "want.price" -> collection("collection/wants")
            kind == "trade.wants" -> id("user_id")?.let { collection("collection/matches", "collection/match/$it") }
                ?: collection("collection/matches")
            kind == "follow.updated" -> {
                val k = id("follow_kind"); val item = id("item_id")
                if (k != null && item != null) collection("collection/following", "collection/following/$k/$item")
                else collection("collection/following")
            }
            kind == "ranking.started" -> id("ranking_id")?.let { collection("collection/ranking/$it") }
            kind.startsWith("friend.") -> WebLink.Screens("account", listOf("friends"))
            kind.startsWith("moderation.") || kind.startsWith("ops.") -> WebLink.Screens("account", emptyList())
            else -> id("event_id")?.let { WebLink.Screens("events", listOf("event/$it")) }
        }
    }

    /** Notification channels, so each kind can be turned off in Android's settings. */
    enum class Channel(val id: String, val title: String, val description: String, val urgent: Boolean) {
        Events("events", "Events", "Pairings, results to confirm, invitations and sign-ups", true),
        Collection("collection", "Collection", "Decks you follow, trades, price drops and cube rankings", false),
        Friends("friends", "Friends", "Friend requests", false),
        Account("account", "From Table 1", "About your account", false),
    }

    fun channel(kind: String): Channel = when {
        kind.startsWith("event.") || kind.startsWith("round.") || kind.startsWith("result.") -> Channel.Events
        kind.startsWith("follow.") || kind.startsWith("trade.") || kind.startsWith("want.") || kind.startsWith("ranking.") -> Channel.Collection
        kind.startsWith("friend.") -> Channel.Friends
        else -> Channel.Account
    }
}
