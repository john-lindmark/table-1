package site.table1.events

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.handleDeeplinks
import io.github.jan.supabase.auth.status.SessionStatus
import kotlinx.coroutines.launch
import site.table1.events.auth.SignIn
import site.table1.events.ui.components.keyboardAwayOnTap
import site.table1.events.data.InstallReferrer
import site.table1.events.data.JoinLink
import site.table1.events.data.WebLink
import site.table1.events.ui.AppRoot
import site.table1.events.ui.theme.Table1Theme
import site.table1.events.util.Push
import site.table1.events.util.Telemetry

class MainActivity : ComponentActivity() {
    private var pendingJoin by mutableStateOf<JoinLink?>(null)
    private var pendingLink by mutableStateOf<WebLink?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Recreated (e.g. after a configuration change): that intent was already handled.
        if (savedInstanceState == null) handle(intent)
        // First launch after installing from a web "Get the app" link: that event, once signed in.
        InstallReferrer.readOnce(this) { url ->
            val link = WebLink.parse(url) ?: return@readOnce
            Telemetry.capture("link_opened", mapOf("to" to link.kind, "via" to "install_referrer"))
            runOnUiThread { if (pendingLink == null && pendingJoin == null) pendingLink = link }
        }
        // Debug builds: `--ez insightsDemo true` opens Insights on the demo packs (src/debug/assets/insights-demo).
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0 && intent?.getBooleanExtra("insightsDemo", false) == true) {
            site.table1.events.insights.InsightsStore.loadDemo(this)
        }
        // Debug builds: `--ez permissionsDemo true` shows the permissions step after sign-in whatever was answered before.
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0 && intent?.getBooleanExtra("permissionsDemo", false) == true) {
            site.table1.events.util.PermissionsStep.demo = true
        }
        // Debug builds: `--es t1Fold tabletop|book` simulates a fold across the middle (contract/foldables-2026-11-10.md).
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            site.table1.events.ui.components.FoldDebug.mode = intent?.getStringExtra("t1Fold")
        }
        setContent {
            Table1Theme {
                // Foldables: the window's folds (Jetpack WindowManager) for the rail and every FoldSplit.
                site.table1.events.ui.components.ProvideWindowFold(this) {
                    // A tap outside a text box puts the keyboard away, on every screen (ui/components/KeyboardAway.kt).
                    androidx.compose.foundation.layout.Box(
                        androidx.compose.ui.Modifier.fillMaxSize().keyboardAwayOnTap(),
                    ) {
                        AppRoot(
                            pendingJoin = pendingJoin, onJoinConsumed = { pendingJoin = null },
                            pendingLink = pendingLink, onLinkConsumed = { pendingLink = null },
                        )
                    }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        Telemetry.syncSurfaces(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        // A tapped notification: its screen, once signed in.
        Push.tapped(intent)?.let { pendingLink = it; return }
        // Widgets, the live notification, tiles and shortcuts open table1:// addresses (as on iOS).
        WebLink.parseApp(intent.dataString)?.let { (link, src) ->
            src?.let { Telemetry.capture("surface_opened", mapOf("source" to it, "target" to (intent.data?.host ?: ""))) }
            if (src == "shortcut") Telemetry.capture("control_used", mapOf("control" to (if (link is WebLink.Tracker) "tracker" else "scan"), "surface" to "shortcut"))
            pendingLink = link
            return
        }
        // Sign in with Apple or Discord comes back as table1://auth-callback#...; supabase-kt finishes the session.
        T1App.supabase.handleDeeplinks(intent) { SignIn.oauthReturned() }
        // table-1.site links (contract/universal-links-2026-10-22.md): the screen the web address shows, once signed in.
        val link = WebLink.parse(intent.dataString) ?: return
        Telemetry.capture("link_opened", mapOf("to" to link.kind))
        when (link) {
            WebLink.SignIn -> SignIn.emailLinkHash(intent.data)?.let { hash -> lifecycleScope.launch { SignIn.verifyEmailLink(hash) } }
            is WebLink.JoinQr -> pendingJoin = link.link
            WebLink.Web -> openInBrowser(this, intent.data ?: return)
            // Standings need no account: someone signed out reads them on the web instead of a sign-in screen.
            is WebLink.Standings ->
                if (T1App.supabase.auth.sessionStatus.value is SessionStatus.NotAuthenticated) openInBrowser(this, Uri.parse(WebLink.standingsUrl(link.eventId)))
                else pendingLink = link
            // So do share links (contract/share-links-2026-10-23.md).
            is WebLink.Shared ->
                if (T1App.supabase.auth.sessionStatus.value is SessionStatus.NotAuthenticated) openInBrowser(this, Uri.parse(WebLink.sharedUrl(link.token)))
                else pendingLink = link
            else -> pendingLink = link
        }
    }
}

/**
 * A table-1.site page the app has no screen for, in the browser. Sent to the browser by package: a plain VIEW intent
 * would come straight back here, since the app is the verified handler for these addresses.
 */
fun openInBrowser(context: Context, uri: Uri) {
    val pm = context.packageManager
    val probe = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com")).addCategory(Intent.CATEGORY_BROWSABLE)
    val browser = pm.resolveActivity(probe, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName
        ?.takeIf { it != "android" && it != context.packageName }
        ?: pm.queryIntentActivities(probe, 0).map { it.activityInfo.packageName }.firstOrNull { it != context.packageName }
    val view = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
    browser?.let { view.setPackage(it) }
    runCatching { context.startActivity(view) }
}
