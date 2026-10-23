package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Share links (contract/share-links-2026-10-23.md) against testdata/share-links/cases.json (iOS ShareLinksTests, web shareLinks.test.ts). */
class ShareLinksTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val doc = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/share-links") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun JsonElement.str(k: String) = (jsonObject[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull

    @Test fun targets() {
        val me = doc["me"]!!.let { (it as JsonPrimitive).content }
        val link = doc["link_url"]!!
        assertEquals(link.str("url"), PartLink.url(link.str("token")!!))
        for (t in doc["targets"]!!.jsonArray) {
            val target = ShareTarget(t.str("part")!!, t.str("id"), t.str("name"))
            assertEquals(t.str("title"), target.title)
            assertEquals(t.str("what"), target.what)
            assertEquals(t.str("confirm"), target.confirmMessage)
            assertEquals(t.str("profile_url"), target.profileUrl(me))
            assertEquals(t.str("id") == null, target.sharePart != null)
        }
    }

    @Test fun sharingGetLinks() {
        val s = json.decodeFromJsonElement(Sharing.serializer(), doc["sharing_get"]!!)
        val links = s.links!!
        assertEquals(2, links.size)
        assertTrue(ShareTarget("deck", "D1", "Burn").matches(links[0]))
        assertTrue(ShareTarget.Wants.matches(links[1]))
        assertFalse(ShareTarget.AllCards.matches(links[1]))
        assertFalse(ShareTarget("cube", "D1", "Burn").matches(links[0]))
    }

    @Test fun olderServerWithoutLinks() {
        assertNull(json.decodeFromString(Sharing.serializer(), """{"profile":"friends","library":"private","record":"private","items":[]}""").links)
    }

    @Test fun sharedView() {
        for (v in doc["shared_view"]!!.jsonArray) {
            val d = json.decodeFromJsonElement(SharedLinkData.serializer(), v.jsonObject["json"]!!)
            assertEquals(v.str("title"), d.title)
            assertEquals(v.str("byline"), d.byline)
        }
    }
}
