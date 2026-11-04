package site.table1.events.util

import android.content.Context
import android.provider.Settings
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import site.table1.events.T1App

/**
 * Google Play's pre-launch report runs the app on Firebase Test Lab phones, which sign in with Google and tap around
 * (contract/test-robots-2026-11-04.md). On those phones the account says so with `account_mark_robot`, so the server
 * keeps what it makes away from real players, and Telemetry sends no analytics.
 */
object TestLab {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val marked = mutableSetOf<String>()
    private var watching = false

    /** Test Lab sets this system setting to "true" on its devices. */
    internal fun isTestLabValue(value: String?): Boolean = value == "true"

    fun isTestLab(context: Context): Boolean =
        isTestLabValue(runCatching { Settings.System.getString(context.contentResolver, "firebase.test.lab") }.getOrNull())

    /** App start: on a Test Lab phone, mark every account that signs in. */
    fun start(context: Context) {
        if (watching || !isTestLab(context)) return
        watching = true
        scope.launch {
            T1App.supabase.auth.sessionStatus.collect { status ->
                val id = (status as? SessionStatus.Authenticated)?.session?.user?.id ?: return@collect
                if (id in marked) return@collect
                runCatching { T1App.supabase.postgrest.rpc("account_mark_robot") }.onSuccess { marked += id }
            }
        }
    }
}
