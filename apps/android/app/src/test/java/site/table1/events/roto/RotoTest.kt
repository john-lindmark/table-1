package site.table1.events.roto

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/* Roto turn maths, delta merging, wire and cards: the same cases as iOS RotoTests and web rotoMath.test.ts. */
class RotoTest {
    @Test fun snakeOrder() {
        assertEquals(listOf(1, 2, 3, 4, 5, 6, 7, 8, 8, 7, 6, 5, 4, 3, 2, 1), (1..16).map { RotoMath.seat(8, it, true) })
        assertEquals(1, RotoMath.seat(8, 17, true))
        assertEquals(listOf(1, 2, 3, 4, 5, 6, 7, 7, 6, 5, 4, 3, 2, 1), (1..14).map { RotoMath.seat(7, it, true) })
        assertEquals(listOf(1, 2, 2, 1, 1, 2), (1..6).map { RotoMath.seat(2, it, true) })
        assertEquals(listOf(1, 2, 3, 1, 2, 3), (1..6).map { RotoMath.seat(3, it, false) })
        assertEquals(45, RotoMath.round(8, 360))
        assertEquals(1, RotoMath.seat(8, 353, true))
        assertEquals(8, RotoMath.seat(8, 360, true))
        for (snake in listOf(true, false)) for (n in 1..360) assertEquals(n, RotoMath.pickNo(RotoMath.seat(8, n, snake), RotoMath.round(8, n), 8, snake))
    }

    @Test fun picksUntilMine() {
        assertEquals(2, RotoMath.picksUntil(3, 0, 8, 360, true))
        assertEquals(0, RotoMath.picksUntil(3, 2, 8, 360, true))
        assertEquals(10, RotoMath.picksUntil(3, 3, 8, 360, true))
        assertEquals(0, RotoMath.picksUntil(8, 8, 8, 360, true))
        assertNull(RotoMath.picksUntil(1, 360, 8, 360, true))
    }

    @Test fun clock() {
        val clock = listOf(RotoClockRange(1, 14400), RotoClockRange(11, 7200), RotoClockRange(31, 1800))
        assertEquals(14400, RotoMath.clockSeconds(clock, 1)); assertEquals(14400, RotoMath.clockSeconds(clock, 10))
        assertEquals(7200, RotoMath.clockSeconds(clock, 11)); assertEquals(1800, RotoMath.clockSeconds(clock, 45))
        assertNull(RotoMath.clockSeconds(null, 3))
        assertEquals("1:42:10", RotoMath.countdownText(6130)); assertEquals("4:05", RotoMath.countdownText(245))
        assertEquals("1 h 30 min", RotoMath.durationText(5400)); assertEquals("4 h", RotoMath.durationText(14400)); assertEquals("30 s", RotoMath.durationText(30))
        assertEquals(listOf(RotoClockRange(1, 14400)), RotoMath.addClockRange(emptyList(), 45))
        assertEquals(listOf(RotoClockRange(1, 14400), RotoClockRange(23, 7200)), RotoMath.addClockRange(listOf(RotoClockRange(1, 14400)), 45))
    }

    @Test fun pairing() {
        assertEquals("round_robin", RotoMath.defaultPairing(2)); assertEquals("round_robin", RotoMath.defaultPairing(8)); assertEquals("swiss", RotoMath.defaultPairing(9))
        assertEquals(7, RotoMath.roundRobinRounds(8)); assertEquals(7, RotoMath.roundRobinRounds(7)); assertEquals(1, RotoMath.roundRobinRounds(0))
        // Everyone meets everyone once over the rounds.
        val ids = (1..6).map { "p$it" }
        val met = (1..RoundRobin.rounds(6)).flatMap { r -> RoundRobin.pairs(ids, r).map { setOf(it.first, it.second) } }
        assertEquals(15, met.toSet().size)
        assertTrue((1..5).all { r -> RoundRobin.pairs((1..5).map { "p$it" }, r).count { it.first == null || it.second == null } == 1 })
    }

    private fun picks(from: Int, to: Int, offset: Int = 100) = (from..to).map { RotoPick(it, RotoMath.seat(8, it, true), it + offset) }

    @Test fun merging() {
        RotoMerge.apply(picks(1, 35), picks(36, 40), 40).let { (p, full) -> assertEquals((1..40).toList(), p.map { it.pickNo }); assertFalse(full) }
        RotoMerge.apply(picks(1, 35), emptyList(), 35).let { (p, full) -> assertEquals(35, p.size); assertFalse(full) }
        RotoMerge.apply(picks(1, 35), emptyList(), 30).let { (p, full) -> assertEquals((1..30).toList(), p.map { it.pickNo }); assertTrue(full) }
        val rewritten = picks(36, 37).toMutableList().also { it[0] = it[0].copy(slot = 132) }
        assertTrue(RotoMerge.apply(picks(1, 35), rewritten, 37).second)
        assertTrue(RotoMerge.apply(picks(1, 10), picks(13, 14), 14).second)
        val fresh = picks(1, 33, 500)
        RotoMerge.apply(emptyList(), fresh, 33).let { (p, full) -> assertEquals(fresh, p); assertFalse(full) }
    }

    @Test fun wire() {
        val s = RotoWire.state(Json.parseToJsonElement("""{"event_id":"e1","phase":"drafting",
            "draft":{"picks_per_player":45,"pick_order":"snake","players":8,"pool_count":360,"picks_made":2,"total_picks":360,"source_list_id":null,
              "clock":[{"from_round":1,"seconds":14400}],"clock_paused":false,"started_at":1760000000,"finished_at":null},
            "on_clock":{"participant_id":"p3","seat":3,"pick_no":3,"round":1,"turn_started_at":1760000100,"turn_seconds":14400,"remaining_seconds":null,"deadline":1760014500,"overdue":false},
            "seats":[{"seat":1,"participant_id":"p1","display_name":"Ann","account":true,"me":false},{"seat":3,"participant_id":"p3","display_name":"Cy","account":false,"me":true}],
            "picks":[[1,1,17,"player",1760000050],[2,2,4,"auto",1760000100]],
            "pool":[[1,"c-1","nonfoil"],[2,"c-2","foil"]],
            "me":{"participant_id":"p3","seat":3,"queue":[5,9],"auto_pick":true,"deck_list_id":"d1"}}""").jsonObject)
        assertEquals("drafting", s.phase); assertEquals(2, s.draft.picksMade); assertEquals(14400, s.draft.clock?.first()?.seconds)
        assertEquals(3, s.onClock?.seat); assertEquals(listOf(17, 4), s.picks.map { it.slot }); assertEquals("auto", s.picks[1].how)
        assertEquals("foil", s.pool?.get(1)?.finish); assertEquals(listOf(5, 9), s.me?.queue); assertEquals("d1", s.me?.deckListId)
        val setup = RotoWire.state(Json.parseToJsonElement("""{"event_id":"e1","phase":"setup","draft":{},"on_clock":null,"seats":[],"picks":[],"pool":null,"me":null}""").jsonObject)
        assertNull(setup.pool); assertNull(setup.onClock); assertEquals(45, setup.draft.picksPerPlayer)
    }

    @Test fun cards() {
        assertEquals(4, RotoCard.manaValue("{2}{U}{U}")); assertEquals(1, RotoCard.manaValue("{X}{R}"))
        assertEquals(2, RotoCard.manaValue("{W/P}{G/U}")); assertEquals(2, RotoCard.manaValue("{1}{R} // {3}{U}"))
        assertEquals("Red", RotoCard.of("a", "Bolt", "Instant", "{R}").group)
        assertEquals("Multicolor", RotoCard.of("a", "Fire // Ice", "Instant // Instant", "{1}{R} // {1}{U}").group)
        assertEquals("Colorless", RotoCard.of("a", "Sol Ring", "Artifact", "{1}").group)
        assertEquals("Lands", RotoCard.of("a", "Tundra", "Land — Plains Island", "").group)
        assertEquals(listOf("W"), RotoCard.of("a", "Kitesail", "Creature — Human", "{W/P}").colors)
    }
}
