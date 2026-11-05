package site.table1.events.widgets

import android.content.ComponentName
import android.content.pm.PackageManager
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

/**
 * Bug #33: Glance's list trampolines (ActionTrampolineActivity, InvisibleActionTrampolineActivity) crashed the app
 * when started without Glance's target intent ("List adapter activity trampoline invoked without specifying target
 * intent", Android 11, build 29897144). Glance only routes clicks through them inside its lazy lists, which no Table 1
 * widget uses, so the manifest turns both off: a stray start now fails at whoever sent it instead of crashing us.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35]) // Robolectric 4.14 stops at 35; the app targets 36
class GlanceTrampolineTest {
    private val context get() = RuntimeEnvironment.getApplication()

    @Test fun theListTrampolinesAreOff() {
        for (name in listOf("ActionTrampolineActivity", "InvisibleActionTrampolineActivity")) {
            val component = ComponentName(context, "androidx.glance.appwidget.action.$name")
            val info = context.packageManager.getActivityInfo(component, PackageManager.MATCH_DISABLED_COMPONENTS)
            assertFalse("$name is enabled (AndroidManifest.xml)", info.enabled)
        }
    }

    /** The trampolines are off because nothing needs them: a Glance lazy list would, so turn them back on first. */
    @Test fun noWidgetUsesAGlanceLazyList() {
        val src = File("src/main/java")
        assertTrue("run from the app module", src.isDirectory)
        val users = src.walk().filter { it.extension == "kt" && it.readText().contains("androidx.glance.appwidget.lazy") }.toList()
        assertTrue("Glance lazy lists need the trampolines back on in AndroidManifest.xml: $users", users.isEmpty())
    }
}
