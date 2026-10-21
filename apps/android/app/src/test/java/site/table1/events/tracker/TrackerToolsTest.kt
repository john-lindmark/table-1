package site.table1.events.tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * The life tracker's Options (contract/life-tracker-options-2026-10-20.md): dice and the chooser.
 * Same cases as iOS TrackerToolsTests.swift and web trackerTools.test.ts.
 */
class TrackerToolsTest {
    @Test fun diceStayOnTheirFacesAndCoverThemAll() {
        val random = Random(1)
        for (sides in Dice.sides) {
            val seen = HashSet<Int>()
            repeat(200) {
                val rolls = Dice.roll(sides, 3, random)
                assertEquals(3, rolls.size)
                assertTrue("D$sides: $rolls", rolls.all { it in 1..sides })
                seen += rolls
            }
            assertEquals((1..sides).toSet(), seen)
        }
    }

    @Test fun diceCountIsClamped() {
        assertEquals(1, Dice.roll(6, 0, Random(2)).size)
        assertEquals(Dice.MAX_COUNT, Dice.roll(6, 99, Random(2)).size)
    }

    @Test fun breakdownOnlyForSeveralDice() {
        assertNull(Dice.breakdown(listOf(17)))
        assertEquals("3 + 5 + 1", Dice.breakdown(listOf(3, 5, 1)))
    }

    private val t0 = 1_000_000L

    @Test fun picksTwoSecondsAfterTheLastFingerLands() {
        val random = Random(3)
        var c = Chooser().down(1, 10f, 10f, t0)
        assertNull("one finger never picks", c.progress(t0 + 5_000))
        assertNull(c.tick(t0 + 5_000, random).winner)
        c = c.down(2, 50f, 50f, t0 + 1_000)
        assertNull("the second finger reset the wait", c.tick(t0 + 2_900, random).winner)
        assertEquals(0.5f, c.progress(t0 + 2_000)!!, 0.001f)
        c = c.tick(t0 + 3_000, random)
        assertTrue(c.winner in listOf(1L, 2L))
        assertSame("picks once", c, c.tick(t0 + 4_000, random))
    }

    @Test fun movingAFingerDoesNotRestartTheWait() {
        var c = Chooser().down(1, 0f, 0f, t0).down(2, 0f, 0f, t0)
        c = c.move(1, 40f, 40f)
        assertEquals(40f, c.fingers.first().x)
        assertNotNull(c.tick(t0 + 2_000, Random(4)).winner)
    }

    @Test fun liftingAFingerBeforeThePickRestartsTheWait() {
        var c = Chooser()
        for (id in 1L..3L) c = c.down(id, 0f, 0f, t0)
        c = c.up(3, t0 + 1_500)
        assertEquals(listOf(1L, 2L), c.fingers.map { it.id })
        assertNull(c.tick(t0 + 3_000, Random(5)).winner)
        assertNotNull(c.tick(t0 + 3_500, Random(5)).winner)
    }

    @Test fun afterThePickNewFingersAreIgnoredUntilEveryoneLifts() {
        var c = Chooser().down(1, 0f, 0f, t0).down(2, 0f, 0f, t0).tick(t0 + 2_000, Random(6))
        c = c.down(3, 0f, 0f, t0 + 2_500)
        assertEquals("late finger ignored", 2, c.fingers.size)
        c = c.up(1, t0 + 3_000)
        assertTrue("circles stay while a finger is still down", c.picked)
        assertEquals(2, c.fingers.size)
        c = c.up(3, t0 + 3_000)
        assertTrue(c.picked)
        c = c.up(2, t0 + 3_200)
        assertFalse(c.picked)
        assertEquals(Chooser(), c)
    }

    @Test fun everyFingerCanWin() {
        val random = Random(7)
        val winners = HashSet<Long>()
        repeat(100) {
            var c = Chooser()
            for (id in 1L..4L) c = c.down(id, 0f, 0f, t0)
            c.tick(t0 + 2_000, random).winner?.let { winners += it }
        }
        assertEquals(setOf(1L, 2L, 3L, 4L), winners)
    }
}
