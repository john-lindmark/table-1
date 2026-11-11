package site.table1.events.tracker

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.data.TrackerState

/**
 * Record is off once the match's result is in (contract/life-tracker-options-2026-10-20.md § After the result is in).
 * Same rule as iOS TrackerResultTests.swift and web tracker.test.ts canRecord.
 */
class TrackerResultTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun stateCarriesResultIn() {
        val s = json.decodeFromString<TrackerState>("""{"session_id":"s1","match_id":"m1","my_side":0,"result_in":true}""")
        assertTrue(s.resultIn)
        val old = json.decodeFromString<TrackerState>("""{"session_id":"s1","match_id":"m1","my_side":0}""")
        assertFalse("older servers leave it out", old.resultIn)
    }

    @Test fun recordOffOnceTheResultIsIn() {
        val open = TrackerDoc(key = "m1", synced = true, mySide = 0)
        assertTrue(open.canRecord)
        assertFalse(open.copy(resultIn = true).canRecord)
        assertFalse("watching never records", open.copy(mySide = null).canRecord)
    }

    @Test fun localTablesAlwaysRecord() {
        assertTrue(TrackerDoc(key = "local", synced = false, mySide = 0, resultIn = true).canRecord)
    }

    @Test fun savedDocsWithoutTheFieldStayOpen() {
        val doc = json.decodeFromString<TrackerDoc>("""{"key":"m1","synced":true,"mySide":0}""")
        assertEquals(false, doc.resultIn)
        assertTrue(doc.canRecord)
    }
}
