package site.table1.events.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import site.table1.events.ui.screens.deckPhotoSize

/** Deck photos go up at most 2048 px on the long side, the same as iOS and web (deckPhotos.test.ts). */
class DeckPhotosTest {
    @Test fun bringsTheLongestSideDownTo2048() {
        assertEquals(2048 to 1536, deckPhotoSize(4032, 3024))
        assertEquals(1536 to 2048, deckPhotoSize(3024, 4032))
    }

    @Test fun neverUpscales() {
        assertEquals(1200 to 900, deckPhotoSize(1200, 900))
    }
}
