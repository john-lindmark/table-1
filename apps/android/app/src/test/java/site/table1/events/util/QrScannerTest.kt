package site.table1.events.util

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * Bug #34: on a phone whose Play services has no code scanner, starting it crashed inside ML Kit's delegate activity
 * (ActivityNotFoundException for ACTION_SCAN_BARCODE), past any try in our code. The scanner now only starts once
 * Play services and the scanner module are there. Robolectric has no Play services, like that phone.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class QrScannerTest {
    @Test fun withoutPlayServicesTheScannerIsNotStarted() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Application>()
        assertFalse(qrScannerReady(context))
        assertEquals(QrScan.Unavailable, scanQr(context))
    }

    @Test fun playInstallsTheScannerWithTheApp() {
        val manifest = listOf("src/main/AndroidManifest.xml", "app/src/main/AndroidManifest.xml")
            .map(::File).first { it.exists() }.readText()
        val deps = Regex("""com\.google\.mlkit\.vision\.DEPENDENCIES"\s+android:value="([^"]*)"""")
            .find(manifest)!!.groupValues[1].split(',')
        assertTrue("barcode_ui" in deps)
        assertTrue("ocr" in deps)
    }
}
