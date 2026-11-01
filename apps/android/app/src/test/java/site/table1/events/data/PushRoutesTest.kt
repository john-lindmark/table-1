package site.table1.events.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A tapped push's screen and its channel (PushRoutes.kt), the same screens as iOS's PushRoutes. */
class PushRoutesTest {
    private fun link(vararg pairs: Pair<String, String>) = PushRoutes.link(mapOf(*pairs))
    private fun screens(tab: String, vararg stack: String) = WebLink.Screens(tab, stack.toList())

    @Test fun eventKindsOpenTheEvent() {
        assertEquals(screens("events", "event/e1"), link("kind" to "round.paired", "event_id" to "e1", "match_id" to "m1"))
        assertEquals(screens("events", "event/e1"), link("kind" to "event.signed_up", "event_id" to "e1"))
        assertNull(link("kind" to "round.paired"))
        assertNull(link("event_id" to "e1"))
    }

    @Test fun collectionKinds() {
        assertEquals(screens("collection", "collection/wants"), link("kind" to "want.price"))
        assertEquals(screens("collection", "collection/matches", "collection/match/u1"), link("kind" to "trade.wants", "user_id" to "u1"))
        assertEquals(screens("collection", "collection/matches"), link("kind" to "trade.wants"))
        assertEquals(screens("collection", "collection/following", "collection/following/deck/d1"),
            link("kind" to "follow.updated", "follow_kind" to "deck", "item_id" to "d1"))
        assertEquals(screens("collection", "collection/ranking/r1"), link("kind" to "ranking.started", "ranking_id" to "r1"))
        assertEquals(screens("collection", "collection/decks", "collection/find?job=j1"), link("kind" to "deck.found", "job_id" to "j1", "status" to "deck"))
        assertNull(link("kind" to "deck.found", "job_id" to ""))
        assertNull(link("kind" to "ranking.started", "ranking_id" to ""))
    }

    @Test fun accountKinds() {
        assertEquals(screens("account", "friends"), link("kind" to "friend.request"))
        assertEquals(screens("account", "notices"), link("kind" to "moderation.notice"))
        assertEquals(screens("account", "review"), link("kind" to "moderation.review"))
        assertEquals(screens("account", "bugs", "bug/12"), link("kind" to "ops.bug", "bug_id" to "12"))
        assertEquals(screens("account", "bugs"), link("kind" to "ops.build"))
    }

    @Test fun channels() {
        assertEquals(PushRoutes.Channel.Events, PushRoutes.channel("result.reported"))
        assertEquals(PushRoutes.Channel.Events, PushRoutes.channel("event.waitlist_in"))
        assertEquals(PushRoutes.Channel.Collection, PushRoutes.channel("want.price"))
        assertEquals(PushRoutes.Channel.Collection, PushRoutes.channel("deck.found"))
        assertEquals(PushRoutes.Channel.Friends, PushRoutes.channel("friend.accepted"))
        assertEquals(PushRoutes.Channel.Account, PushRoutes.channel("moderation.review"))
        assertEquals(PushRoutes.Channel.Account, PushRoutes.channel("ops.build"))
    }
}
