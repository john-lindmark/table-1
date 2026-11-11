package site.table1.events.util

import io.ktor.client.plugins.HttpRequestTimeoutException
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.library.CollectionOp
import site.table1.events.library.ListEntry
import site.table1.events.library.applyListOps
import java.io.File
import java.io.IOException

/** Offline rules (contract/offline-2026-10-31.md), shared with iOS OfflineTests and web offline.test.ts. */
class OfflineTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/offline") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun op(o: kotlinx.serialization.json.JsonObject) = CollectionOp(
        o["card_id"]!!.jsonPrimitive.content, o["finish"]?.jsonPrimitive?.content ?: "nonfoil",
        o["condition"]?.jsonPrimitive?.content ?: "NM", o["lang"]?.jsonPrimitive?.content ?: "en",
        o["delta"]?.jsonPrimitive?.int, o["qty"]?.jsonPrimitive?.int, o["binder_id"]?.jsonPrimitive?.content,
    )

    @Test fun ago() {
        for (k in c["ago"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(k["label"]!!.jsonPrimitive.content, Offline.ago(k["seconds"]!!.jsonPrimitive.long))
        }
    }

    @Test fun notice() {
        for (k in c["notice"]!!.jsonArray.map { it.jsonObject }) {
            val name = k["name"]!!.jsonPrimitive.content
            val n = Offline.notice(k["failed"]!!.jsonPrimitive.boolean, k["savedAgo"]?.jsonPrimitive?.longOrNull, k["error"]?.jsonPrimitive?.contentOrNull)
            assertEquals(name, k["text"]?.jsonPrimitive?.contentOrNull, n?.first)
            assertEquals(name, k["isError"]!!.jsonPrimitive.boolean, n?.second ?: false)
        }
    }

    @Test fun queues() {
        for (k in c["queues"]!!.jsonArray.map { it.jsonObject }) {
            val ops = k["ops"]!!.jsonArray.map { op(it.jsonObject) }
            assertEquals(k["name"]!!.jsonPrimitive.content, k["queued"]!!.jsonPrimitive.boolean, Offline.queues(ops, k["network"]!!.jsonPrimitive.boolean))
        }
    }

    @Test fun deltasAndShown() {
        for (k in c["deltas"]!!.jsonArray.map { it.jsonObject }) {
            val batches = k["batches"]!!.jsonArray.map { b -> b.jsonArray.map { op(it.jsonObject) } }
            assertEquals(k["name"]!!.jsonPrimitive.content, k["deltas"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }, Offline.deltas(batches))
        }
        for (k in c["shown"]!!.jsonArray.map { it.jsonObject }) {
            val deltas = k["deltas"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }
            assertEquals(k["name"]!!.jsonPrimitive.content, k["qty"]!!.jsonPrimitive.int, k["serverQty"]!!.jsonPrimitive.int + (deltas[k["key"]!!.jsonPrimitive.content] ?: 0))
        }
    }

    @Test fun networkErrors() {
        assertTrue(Offline.isNetwork(IOException("unreachable")))
        assertTrue(Offline.isNetwork(RuntimeException("x", IOException("y"))))
        assertTrue(Offline.isNetwork(HttpRequestTimeoutException("https://x", 25_000)))
        assertTrue(Offline.isNetwork(RuntimeException("wrapped", java.net.UnknownHostException("x"))))
        assertFalse(Offline.isNetwork(CancellationException("left the screen")))
        assertFalse(Offline.isNetwork(IllegalStateException("That event isn't available")))
    }

    /** The ops a queued list_edit carries apply here the way the server applies them. */
    @Test fun listOpsApplyLocally() {
        val start = listOf(ListEntry("a", "main", 4), ListEntry("b", "side", 2, "foil"))
        val ops = listOf(
            buildJsonObject { put("card_id", "a"); put("board", "main"); put("finish", "nonfoil"); put("lang", "en"); put("delta", -1) },
            buildJsonObject { put("card_id", "c"); put("board", "main"); put("finish", "nonfoil"); put("lang", "en"); put("delta", 2) },
            buildJsonObject { put("card_id", "b"); put("finish", "foil"); put("lang", "en"); put("from", "side"); put("to", "main") },
            buildJsonObject { put("card_id", "a"); put("board", "main"); put("finish", "nonfoil"); put("lang", "en"); put("to_card_id", "a2"); put("to_finish", "nonfoil"); put("to_lang", "ja"); put("qty", 1) },
            buildJsonObject { put("card_id", "c"); put("board", "main"); put("finish", "nonfoil"); put("lang", "en"); put("qty", 0) },
        )
        val out = applyListOps(start, ops)
        assertEquals(listOf(ListEntry("a", "main", 2), ListEntry("b", "main", 2, "foil"), ListEntry("a2", "main", 1, "nonfoil", "ja")), out)
        assertNull(out.firstOrNull { it.cardId == "c" })
    }
}

/** Bug #39: an offline catalog_info call (supabase-kt's HttpRequestException around an UnknownHostException) went to Sentry. */
class TelemetryReportsTest {
    @Test fun offlineIsNotReported() {
        val offline = io.github.jan.supabase.exceptions.HttpRequestException(
            "Unable to resolve host \"aaozhfcbvqrgkkrihkrd.supabase.co\": No address associated with hostname",
            io.ktor.client.request.HttpRequestBuilder(),
        )
        assertFalse(Telemetry.reports(offline))
        assertFalse(Telemetry.reports(java.net.UnknownHostException("x")))
        assertFalse(Telemetry.reports(CancellationException("left")))
        assertTrue(Telemetry.reports(IllegalStateException("a real bug")))
    }
}
