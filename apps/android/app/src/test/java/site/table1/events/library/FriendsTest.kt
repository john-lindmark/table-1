package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Friends, sharing and trade matches (contract/friends-sharing-2026-10-18.md). The matcher runs the shared cases in
 * testdata/trade-matches/cases.json (the same as the server's 80_friends_sharing_test.sql); iOS FriendsTests and web
 * friends.test.ts read the same file.
 */
class FriendsTest {
    private val cases = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/trade-matches") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject["cases"]!!.jsonArray

    private fun JsonElement.str(k: String) = (jsonObject[k] as? JsonPrimitive)?.contentOrNull
    private fun JsonElement.num(k: String) = jsonObject[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.double

    @Test fun matcherSharedCases() {
        assertTrue(cases.size >= 5)
        for (c in cases) {
            val wants = c.jsonObject["wants"]!!.jsonArray.map {
                TradeMatcher.WantIn(it.str("oracle_id")!!, it.str("card_id"), it.str("finish"), it.jsonObject["qty"]!!.jsonPrimitive.int, it.num("max_usd"))
            }
            val copies = c.jsonObject["copies"]!!.jsonArray.map {
                TradeMatcher.CopyIn(it.str("oracle_id")!!, it.str("card_id")!!, it.str("finish")!!, it.str("condition")!!, it.str("lang")!!,
                    it.str("binder_id"), it.jsonObject["qty"]!!.jsonPrimitive.int, it.num("usd"))
            }
            val want = c.jsonObject["lines"]!!.jsonArray.map {
                listOf(it.str("card_id"), it.str("finish"), it.str("condition"), it.str("lang"), it.jsonObject["qty"]!!.jsonPrimitive.int.toString(),
                    it.str("want"), it.jsonObject["over_max"]!!.jsonPrimitive.boolean.toString())
            }
            val got = TradeMatcher.lines(wants, copies).map {
                listOf(it.cardId, it.finish, it.condition, it.lang, it.qty.toString(), it.want.tier, (it.overMax == true).toString())
            }
            assertEquals(c.jsonObject["name"]!!.jsonPrimitive.content, want, got)
        }
    }

    @Test fun shownOrderPutsOverMaxLast() {
        val w = WantKey("o")
        val lines = listOf(MatchLine("a", "nonfoil", qty = 1, want = w, usd = 50.0, overMax = true),
            MatchLine("b", "nonfoil", qty = 1, want = w, usd = 1.0, overMax = false),
            MatchLine("c", "nonfoil", qty = 2, want = w, usd = 3.0, overMax = false))
        assertEquals(listOf("c", "b", "a"), TradeMatcher.shown(lines).map { it.cardId })
        assertEquals(7.0, TradeMatcher.value(lines, true), 1e-9)
        assertEquals(57.0, TradeMatcher.value(lines, false), 1e-9)
    }

    @Test fun sharingStartsPrivate() {
        val s = Sharing()
        for (p in SharePart.libraryParts + SharePart.Record) assertEquals(p.wire, Visibility.Private, SharingRules.effective(s, p))
        assertEquals(0, SharingRules.sharedCount(s))
        assertEquals("Profile friends · nothing shared", SharingRules.summary(s))
    }

    @Test fun inheritChainAndItems() {
        val s = Sharing(library = "friends", decks = "private")
        assertEquals(Visibility.Friends, SharingRules.effective(s, SharePart.Wants))
        val deck = ShareItem("deck", "d", "Burn")
        assertEquals(Visibility.Private, SharingRules.effective(s, deck))
        val own = deck.copy(visibility = "public")
        assertEquals(Visibility.Public, SharingRules.effective(s, own))
        assertEquals(6, SharingRules.sharedCount(s.copy(items = listOf(own))))
    }

    @Test fun profileCapsParts() {
        val s = Sharing(forTrade = "public")
        assertTrue(SharingRules.capped(s, Visibility.Public))
        assertEquals(Visibility.Friends, SharingRules.reach(s, Visibility.Public))
        assertFalse(SharingRules.capped(s.copy(profile = "public"), Visibility.Public))
        assertEquals(Visibility.Private, SharingRules.reach(s.copy(profile = "private"), Visibility.Public))
    }

    @Test fun seesMatchesServer() {
        val rows = listOf(
            listOf(3, Visibility.Private, Visibility.Private, true), listOf(1, Visibility.Friends, Visibility.Friends, true),
            listOf(1, Visibility.Friends, Visibility.Private, false), listOf(1, Visibility.Private, Visibility.Public, false),
            listOf(0, Visibility.Public, Visibility.Public, true), listOf(0, Visibility.Friends, Visibility.Public, false),
            listOf(0, Visibility.Public, Visibility.Friends, false), listOf(-1, Visibility.Public, Visibility.Public, false),
        )
        for (r in rows) assertEquals(r.toString(), r[3], SharingRules.sees(r[0] as Int, r[1] as Visibility, r[2] as Visibility))
    }

    @Test fun settingsChangeJson() {
        assertEquals("""{"wants":null}""", SharingRules.change(SharePart.Wants, null).toString())
        assertEquals("""{"items":[{"kind":"binder","id":"b1","visibility":"friends"}]}""",
            SharingRules.change(ShareItem("binder", "b1", "Trades", true), Visibility.Friends).toString())
    }

    @Test fun decodesServerShapes() {
        val json = Json { ignoreUnknownKeys = true }
        val p = json.decodeFromString(ProfileData.serializer(), """
            {"user_id":"u","display_name":"Ben","relation":"friend","friends_since":"2026-10-18","visible":true,
             "sections":{"for_trade":{"cards":7},"binders":[{"id":"b","name":"T","for_trade":true,"cards":7}],"decks":[],"cubes":[],
             "record":{"match_wins":1,"match_losses":2,"match_draws":0,"events_played":1}}}""")
        assertEquals(3, p.sectionCount)
        val m = json.decodeFromString(TradeMatch.serializer(), """
            {"user_id":"u","display_name":"Ben","friend":true,"have_copies":1,"want_copies":0,"have_usd":2.0,"want_usd":0,"they_want":[],
             "they_have":[{"card_id":"c","finish":"foil","condition":"NM","lang":"en","qty":1,"usd":2.0,"over_max":false,
                           "want":{"oracle_id":"o","card_id":"c","finish":"foil"}}]}""")
        assertEquals("exact", m.theyHave[0].want.tier)
        assertEquals("Has 1 you want", m.summary)
        assertEquals("Has 1", m.short)
    }

    @Test fun parsesProfileCardRows() {
        fun row(vararg v: Any?) = v.map { when (it) { null -> JsonNull; is Int -> JsonPrimitive(it); else -> JsonPrimitive(it as String) } }
        assertEquals(ProfileCard(cardId = "c", finish = "foil", qty = 3), ProfileCard.parse("all_cards", row("c", "foil", 3)))
        assertEquals(ProfileCard(cardId = "c", finish = "nonfoil", condition = "LP", lang = "ja", qty = 2),
            ProfileCard.parse("binder", row("c", "nonfoil", "LP", "ja", 2)))
        assertEquals(ProfileCard(cardId = "c", board = "side", qty = 4), ProfileCard.parse("deck", row("c", "side", 4)))
        assertEquals(ProfileCard(oracleId = "o", qty = 1), ProfileCard.parse("wants", row("o", null, null, 1)))
        assertNull(ProfileCard.parse("wants", row("o")))
    }

    private val json = Json { ignoreUnknownKeys = true }

    /** Privacy fixes: an email ask comes back as {email, at} with no user_id; asks by id stay a Person. */
    @Test fun decodesSentByIdAndByEmail() {
        val l = json.decodeFromString(FriendsList.serializer(), """
            {"friends":[],"incoming":[],"blocked":[],"outgoing":[
              {"email":"jo@example.com","at":"2026-10-18T10:00:00Z"},
              {"user_id":"u1","display_name":"Lee Park","handle":null,"avatar_url":null,"at":"2026-10-17T10:00:00Z"}]}
        """.trimIndent())
        assertEquals(2, l.outgoing.size)
        assertNull(l.outgoing[0].person)
        assertEquals("jo@example.com", l.outgoing[0].email)
        assertEquals("2026-10-18T10:00:00Z", l.outgoing[0].at)
        assertEquals("jo@example.com", l.outgoing[0].label)
        assertEquals("u1", l.outgoing[1].person?.userId)
        assertEquals("Lee Park", l.outgoing[1].label)
        assertEquals("2026-10-17T10:00:00Z", l.outgoing[1].at)
        assertTrue(l.outgoing[0].key != l.outgoing[1].key)
        // Round trip.
        assertEquals(l, json.decodeFromString(FriendsList.serializer(), json.encodeToString(FriendsList.serializer(), l)))
    }

    /** Older servers sent only Person rows; a null user_id reads as an address. */
    @Test fun decodesOldSentShape() {
        val l = json.decodeFromString(FriendsList.serializer(), """
            {"outgoing":[{"user_id":"u2","display_name":"Kai","at":"2026-10-16T10:00:00Z"},
                         {"user_id":null,"email":"x@example.com","at":"2026-10-15T10:00:00Z"}]}
        """.trimIndent())
        assertEquals(listOf("u2", null), l.outgoing.map { it.person?.userId })
        assertEquals("x@example.com", l.outgoing[1].email)
    }

    /** value_usd is on your own profile only now; an older server's value on someone else's profile isn't shown. */
    @Test fun collectionValueOnlyOnYourOwnProfile() {
        fun profile(relation: String, allCards: String) = json.decodeFromString(ProfileData.serializer(), """
            {"user_id":"u","display_name":"A","relation":"$relation","visible":true,"sections":{"all_cards":$allCards}}
        """.trimIndent())
        assertEquals(42.5, profile("self", """{"cards":10,"printings":8,"value_usd":42.5}""").valueUsd!!, 0.0)
        val theirs = profile("friend", """{"cards":10,"printings":8}""")
        assertEquals(10, theirs.sections.allCards?.cards)
        assertNull(theirs.sections.allCards?.valueUsd)
        assertNull(theirs.valueUsd)
        assertNull(profile("friend", """{"cards":10,"printings":8,"value_usd":42.5}""").valueUsd)
    }

    @Test fun sharedDecksAndCubes() {
        val rows = listOf(
            ProfileCard(cardId = "a", board = "main", qty = 2), ProfileCard(cardId = "b", board = "side", qty = 1),
            ProfileCard(cardId = "a", board = "main", qty = 1), ProfileCard(cardId = "a", board = "side", qty = 1),
            ProfileCard(cardId = "c", board = "maybe", qty = 3), ProfileCard(cardId = null, board = "main", qty = 1),
        )
        assertEquals(listOf(ListEntry("a", "main", 3), ListEntry("b", "side", 1), ListEntry("a", "side", 1), ListEntry("c", "maybe", 3)),
            SharedList.entries(rows))
        assertEquals(6, SharedList.count(rows, ListKind.Deck))
        assertEquals(9, SharedList.count(rows, ListKind.Cube))
        assertEquals("Copied from Sam's Mono Red", SharedList.copyNote("Sam", "Mono Red"))
        assertEquals("Copied from Mono Red", SharedList.copyNote(null, "Mono Red"))
        assertEquals(ListKind.Deck, SharedList.kind("deck"))
        assertEquals(ListKind.Cube, SharedList.kind("cube"))
        assertNull(SharedList.kind("binder"))
    }

    @Test fun profileCardsPageDecodesByRuntimeLookup() {
        // supabase-kt's decodeAs<T>() looks the serializer up at run time: a shared deck/cube/binder failed with
        // "Serializer for class 'ProfileCardsPage' is not found" after its @Serializable moved onto SharedList.
        @Suppress("UNCHECKED_CAST")
        val s = kotlinx.serialization.serializer(kotlin.reflect.typeOf<ProfileCardsPage>()) as kotlinx.serialization.KSerializer<ProfileCardsPage>
        val page = Json.decodeFromString(s, """{"rows": [["c1", "main", 2]], "more": true}""")
        assertTrue(page.more)
        assertEquals(2, ProfileCard.parse("deck", page.rows.single())?.qty)
    }
}
