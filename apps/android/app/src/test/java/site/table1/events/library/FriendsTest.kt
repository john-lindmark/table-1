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
}
