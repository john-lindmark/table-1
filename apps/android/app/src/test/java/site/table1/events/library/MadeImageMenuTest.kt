package site.table1.events.library

import android.app.Application
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Long press on a made picture (deck image, top 100): Copy, Save to Photos, Share
 *  (contract/deck-image-2026-10-20.md § Long press). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class MadeImageMenuTest {
    @get:Rule val rule = createComposeRule()

    private val image = Bitmap.createBitmap(32, 18, Bitmap.Config.ARGB_8888)

    @Test fun copyPutsTheJpegOnTheClipboard() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        copyImage(context, image, "izzet-murktide.jpg")
        val clip = (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip!!
        val uri = clip.getItemAt(0).uri
        assertEquals("content", uri.scheme)
        assertEquals("${context.packageName}.avatars", uri.authority)
        assertTrue(clip.description.hasMimeType("image/jpeg"))
    }

    @Test fun aLongPressOffersCopySaveAndShare() {
        val picked = mutableListOf<String>()
        val actions = MadeImageActions(
            copy = { picked += "copy"; "Copied the image." },
            save = { picked += "save"; "Saved to Photos." },
            share = { picked += "share" },
        )
        rule.setContent { ZoomablePreview(image, "Deck image", "Izzet Murktide", "deck_image", actions) }
        rule.onNodeWithContentDescription("Deck image, Izzet Murktide", substring = true).performTouchInput { longClick() }
        rule.onNodeWithText("Copy").assertExists()
        rule.onNodeWithText("Save to Photos").assertExists()
        rule.onNodeWithText("Share").performClick()
        rule.waitForIdle()
        assertEquals(listOf("share"), picked)
        rule.onNodeWithText(PREVIEW_HINT, ignoreCase = true).assertExists()
    }
}
