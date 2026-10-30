package site.table1.events.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Locale

/* The widgets and the live notification's logic (contract/widgets-2026-10-22.md), the same cases as iOS
   WidgetLogicTests: the Next event pick and time text, the value history, the organizer's next step. */
class LiveSurfacesTest {
    private val now = Instant.parse("2026-10-22T12:00:00Z")

    private fun event(id: String, bucket: String = "upcoming", status: String = "open", startsIn: Long? = null, round: Int = 0) =
        NextEventItem(id, id, status, bucket, organizing = false, playing = true,
            startsAt = startsIn?.let { now.plusSeconds(it).toString() }, numberOfRounds = 4, currentRound = round, format = "modern")

    @Test fun pickPutsLiveFirstThenSoonestThenUndatedAndHidesCancelledAndPast() {
        val picked = NextEvent.pick(listOf(event("undated"), event("later", startsIn = 86400), event("cancelled", status = "cancelled", startsIn = 60),
            event("past", bucket = "past"), event("soon", startsIn = 3600), event("live", bucket = "live", round = 2)))
        assertEquals(listOf("live", "soon", "later", "undated"), picked.map { it.id })
    }

    @Test fun timeText() {
        val en = Locale.US
        assertEquals("Live · R2/4", NextEvent.timeText(event("l", bucket = "live", round = 2), now))
        assertEquals("Not scheduled", NextEvent.timeText(event("u"), now))
        assertEquals("Starting now", NextEvent.timeText(event("p", startsIn = -600), now))
        assertEquals("In 45m", NextEvent.timeText(event("m", startsIn = 45 * 60), now))
        assertEquals("In 2h 10m", NextEvent.timeText(event("h", startsIn = 2 * 3600 + 10 * 60), now))
        val plain = { s: String -> s.replace(' ', ' ') }
        val days = plain(NextEvent.timeText(event("d", startsIn = 2 * 86400 + 6 * 3600 + 1800), now, ZoneOffset.UTC, en))
        assertTrue(days, days.startsWith("Sat") && days.endsWith("6:30 PM"))
        val weeks = plain(NextEvent.timeText(event("w", startsIn = 8 * 86400), now, ZoneOffset.UTC, en))
        assertTrue(weeks, weeks.startsWith("Oct 30") && weeks.endsWith("12:00 PM"))
    }

    @Test fun parsesPostgresTimestamps() {
        assertTrue(NextEventItem("e", "e", "open", "upcoming", false, false, startsAt = "2026-10-22T18:00:00.123456+00:00").start != null)
        assertNull(NextEventItem("e", "e", "open", "upcoming", false, false, startsAt = "tomorrow").start)
    }

    @Test fun reloadsJustAfterTheNextStartWithinTwelveHours() {
        assertEquals(now.plusSeconds(11 * 60), NextEvent.nextReload(listOf(event("s", startsIn = 10 * 60)), now))
        assertEquals(now.plusSeconds(30 * 60), NextEvent.nextReload(listOf(event("x", startsIn = 5 * 3600)), now))
        assertEquals(now.plusSeconds(3 * 3600), NextEvent.nextReload(listOf(event("y", startsIn = 3 * 86400)), now))
    }

    private val today = LocalDate.parse("2026-10-22")

    @Test fun onePointPerDayLastValueWins() {
        var r = ValueHistory.record(null, "u", 100.0, 1, 1, today)
        r = ValueHistory.record(r, "u", 105.004, 1, 1, today)
        assertEquals(listOf(ValuePoint("2026-10-22", 105.0)), r.points)
        assertNull("one day: no change yet", r.change(today = today))
    }

    @Test fun changeOverSevenDaysOrShorterHistory() {
        var r: ValueRecord? = null
        listOf(100.0, 90.0, 120.0, 130.0, 125.0, 140.0, 150.0, 160.0, 170.0).forEachIndexed { i, v ->
            r = ValueHistory.record(r, "u", v, 1, 1, today.plusDays((i - 8).toLong()))
        }
        val week = r!!.change(today = today)!!
        assertEquals(80.0, week.first, 0.001)
        assertEquals(7, week.second)
        var short = ValueHistory.record(null, "u", 50.0, 1, 1, today.minusDays(2))
        short = ValueHistory.record(short, "u", 45.0, 1, 1, today)
        assertEquals(-5.0, short.change(today = today)!!.first, 0.001)
        assertEquals(2, short.change(today = today)!!.second)
    }

    @Test fun keepsThirtyDaysAndStartsFreshForAnotherAccount() {
        var r: ValueRecord? = null
        for (i in 0 until 40) r = ValueHistory.record(r, "u", i.toDouble(), 1, 1, today.plusDays((i - 39).toLong()))
        assertEquals(30, r!!.points.size)
        assertEquals(today.minusDays(29).toString(), r!!.points.first().day)
        r = ValueHistory.record(r, "other", 7.0, 1, 1, today)
        assertEquals("other", r!!.userId)
        assertEquals(1, r!!.points.size)
    }

    private fun org(phase: String = "live", round: Int = 2, matches: Int = 8, done: Int = 5, disputes: Int = 0, guests: Int = 0) =
        OrgState(phase, round, 4, 3000, matches = matches, done = done, waiting = matches - done, disputes = disputes, guestWaiting = guests, players = 16)

    @Test fun organizerNextStep() {
        assertEquals("Waiting on 3 results", org().nextStep)
        assertEquals("Waiting on 1 result", org(done = 7).nextStep)
        assertEquals("Ready: Pair round 3", org(done = 8).nextStep)
        assertTrue(org(done = 8).isReady)
        assertEquals("Ready: Finish event", org(round = 4, done = 8).nextStep)
        assertEquals("Round 2 recorded · Pair round 3", org("between", round = 2, matches = 0, done = 0).nextStep)
        assertEquals("Pair round 1", org("between", round = 0, matches = 0, done = 0).nextStep)
        assertEquals("Event complete", org("complete").nextStep)
        assertEquals(listOf("1 dispute to decide", "2 to enter yourself"), org(disputes = 1, guests = 2).flags)
        assertEquals(emptyList<String>(), org("between", disputes = 1).flags)
    }

    @Test fun decodesTheServersOrganizerState() {
        val json = Json { ignoreUnknownKeys = true }
        val r = json.decodeFromString<LiveStateResponse>("""{"snapshots":[],"organizer":[{"eventId":"e","eventName":"Friday","state":{"phase":"live","round":2,"rounds":4,"roundSeconds":3000,"pausedRemaining":1200,"matches":8,"done":5,"waiting":3,"disputes":1,"guestWaiting":1,"players":16,"updatedAt":1761134400}}]}""")
        assertEquals("20:00", r.organizer.first().state.pausedText)
        assertEquals("5/8 in", r.organizer.first().state.resultsText)
        assertEquals(emptyList<OrganizerSnapshot>(), json.decodeFromString<LiveStateResponse>("""{"snapshots":[]}""").organizer)
    }
}
