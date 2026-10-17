package site.table1.events.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

/** Expected values come from the iOS implementation (apps/ios/Table1/UI/Avatar.swift) run on the same inputs. */
class AvatarStyleTest {
    @Test fun initials() {
        mapOf(
            "Jane van Dyke" to "JD",
            "jane" to "J",
            "  " to "?",
            "" to "?",
            "(Bob) Smith-Jones" to "BS",
            "émile zola" to "ÉZ",
            "李 小龍" to "李小",
            "- Ann -" to "A",
            "42 Wallaby" to "4W",
        ).forEach { (name, want) -> assertEquals(name, want, AvatarStyle.initials(name)) }
    }

    @Test fun colorIndex() {
        mapOf(
            "" to 5,
            "a" to 4,
            "jane" to 1,
            "jane van dyke" to 7,
            "3f2a9c1e-5b7d-4e8a-9c0f-1a2b3c4d5e6f" to 7,
            "00000000-0000-0000-0000-000000000000" to 1,
            "émile" to 4,
        ).forEach { (seed, want) -> assertEquals(seed, want, AvatarStyle.colorIndex(seed)) }
    }

    @Test fun seed() {
        assertEquals("3f2a9c1e-5b7d-4e8a-9c0f-1a2b3c4d5e6f", AvatarStyle.seed("3F2A9C1E-5B7D-4E8A-9C0F-1A2B3C4D5E6F", "x"))
        assertEquals("jane van dyke", AvatarStyle.seed(null, "  Jane Van Dyke "))
    }
}
