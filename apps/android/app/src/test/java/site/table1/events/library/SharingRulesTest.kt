package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The sharing UX rules (contract/friends-sharing-2026-10-18.md § UX rules) on testdata/sharing/cases.json, the file
 * iOS FriendsTests and web friends.test.ts read: what a change newly shows (asks first), the Sharing summary lines,
 * and your own profile as a friend or anyone sees it.
 */
class SharingRulesTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val all = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/sharing") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun settings(e: JsonElement) = json.decodeFromJsonElement(Sharing.serializer(), e)
    private fun strings(e: JsonElement?) = e!!.jsonArray.map { it.jsonPrimitive.content }

    @Test fun anyoneNeverPublic() {
        assertEquals("Anyone", Visibility.Public.label)
        assertEquals("public", Visibility.Public.wire)
    }

    @Test fun wideningSharedCases() {
        val cases = all["widening"]!!.jsonArray
        assertTrue(cases.size >= 6)
        for (c in cases) {
            val o = c.jsonObject
            val name = o["name"]!!.jsonPrimitive.content
            val w = SharingRules.widening(settings(o["before"]!!), settings(o["after"]!!))
            assertEquals(name, strings(o["friends"]), w.friends)
            assertEquals(name, strings(o["anyone"]), w.anyone)
            assertEquals(name, o["all_cards_to_anyone"]!!.jsonPrimitive.boolean, w.allCardsToAnyone)
            assertEquals(name, o["profile_to_anyone"]!!.jsonPrimitive.boolean, w.profileToAnyone)
            // Undoing a widening never asks.
            if (!w.isEmpty) assertTrue(name, SharingRules.widening(settings(o["after"]!!), settings(o["before"]!!)).isEmpty)
        }
    }

    @Test fun seesLineSharedCases() {
        for (c in all["sees"]!!.jsonArray) {
            val o = c.jsonObject
            val s = settings(o["settings"]!!)
            assertEquals(o["name"]!!.jsonPrimitive.content, o["friends"]!!.jsonPrimitive.content, SharingRules.seesLine(s, 1))
            assertEquals(o["name"]!!.jsonPrimitive.content, o["anyone"]!!.jsonPrimitive.content, SharingRules.seesLine(s, 0))
        }
    }

    @Test fun viewAsSharedCases() {
        val profile = json.decodeFromJsonElement(ProfileData.serializer(), all["view_as_profile"]!!)
        assertEquals("self", profile.relation)
        for (c in all["view_as"]!!.jsonArray) {
            val o = c.jsonObject
            val name = o["name"]!!.jsonPrimitive.content
            val level = o["level"]!!.jsonPrimitive.int
            val v = SharingRules.viewAs(profile, settings(o["settings"]!!), level)
            val want = o["want"]!!.jsonObject
            fun n(k: String) = want[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.intOrNull
            assertEquals(name, want["visible"]!!.jsonPrimitive.boolean, v.visible)
            assertEquals(name, n("all_cards"), v.sections.allCards?.cards)
            assertEquals(name, want["value"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull?.toDouble(), v.sections.allCards?.valueUsd)
            assertEquals(name, n("for_trade"), v.sections.forTrade?.cards)
            assertEquals(name, n("wants"), v.sections.wants?.cards)
            assertEquals(name, strings(want["binders"]), v.sections.binders.orEmpty().map { it.name })
            assertEquals(name, strings(want["decks"]), v.sections.decks.orEmpty().map { it.name })
            assertEquals(name, strings(want["cubes"]), v.sections.cubes.orEmpty().map { it.name })
            assertEquals(name, want["record"]!!.jsonPrimitive.boolean, v.sections.record != null)
            assertEquals(name, if (level >= 1) "friend" else "none", v.relation)
        }
    }
}
