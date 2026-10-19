package site.table1.events.util

import android.content.Context
import android.util.Log
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import io.sentry.Breadcrumb
import io.sentry.HttpStatusCodeRange
import io.sentry.Sentry
import io.sentry.SentryEvent
import io.sentry.android.core.SentryAndroid
import io.sentry.okhttp.SentryOkHttpInterceptor
import io.sentry.protocol.SentryTransaction
import io.sentry.protocol.User
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.Interceptor
import site.table1.events.BuildConfig
import site.table1.events.T1App

/**
 * Crash reporting (Sentry) and product analytics, per contract/telemetry-2026-10-15.md, mirroring iOS Telemetry.swift.
 * Sentry is off when `T1_SENTRY_DSN` is empty, in Debug unless built with `-PT1_TELEMETRY=1`, and when the person turns
 * off "Share usage and crash data" in Account. PostHog isn't wired on Android yet: `capture` logs in Debug until it lands.
 * Properties are counts, enums and booleans only: never names, free text, join codes or row ids.
 */
object Telemetry {
    private const val OPT_OUT_KEY = "telemetry.optedOut"
    private val prefs get() = T1App.instance.getSharedPreferences("telemetry", Context.MODE_PRIVATE)
    private var sentryOn = false
    private var watchingSession = false

    val sharing: Boolean get() = !prefs.getBoolean(OPT_OUT_KEY, false)

    private val allowedInBuild get() = !BuildConfig.DEBUG || BuildConfig.TELEMETRY_IN_DEBUG
    private val environment get() = if (BuildConfig.DEBUG) "debug" else BuildConfig.RELEASE_ENVIRONMENT

    /** Called first thing in Application.onCreate, before anything else can crash. */
    fun start(context: Context) {
        if (!allowedInBuild || !sharing || BuildConfig.SENTRY_DSN.isEmpty()) return
        val env = environment
        SentryAndroid.init(context) { o ->
            o.dsn = BuildConfig.SENTRY_DSN
            o.environment = env
            o.release = "site.table1.events@${BuildConfig.VERSION_NAME}+${BuildConfig.VERSION_CODE}"
            o.isSendDefaultPii = false
            o.isDebug = BuildConfig.DEBUG
            o.tracesSampleRate = if (env == "production") 0.1 else 1.0
            o.isAnrEnabled = true
            // Screens can show players' names; profiling and session replay stay off (no replay module either).
            o.isAttachScreenshot = false
            o.isAttachViewHierarchy = false
            o.setBeforeBreadcrumb { crumb, _ -> scrub(crumb) }
            o.setBeforeSend { event, _ -> scrub(event) }
            o.setBeforeSendTransaction { tx, _ -> scrub(tx) }
        }
        sentryOn = true
        watchSession()
    }

    /**
     * Sentry for the Supabase client's OkHttp engine: breadcrumbs, spans and failed-request events for 5xx only,
     * since 4xx is how RLS and validation reply. A no-op while Sentry is off.
     */
    fun httpInterceptor(): Interceptor = SentryOkHttpInterceptor(
        captureFailedRequests = true,
        failedRequestStatusCodes = listOf(HttpStatusCodeRange(500, 599)),
    )

    // identity

    /** Signed in (or a restored session) sets the user to the Supabase id; signed out or deleted clears it. */
    private fun watchSession() {
        if (watchingSession) return
        watchingSession = true
        CoroutineScope(SupervisorJob() + Dispatchers.Main).launch {
            T1App.supabase.auth.sessionStatus.collect { status ->
                when (status) {
                    is SessionStatus.Authenticated -> status.session.user?.id?.let { identify(it) }
                    is SessionStatus.NotAuthenticated -> reset()
                    else -> Unit
                }
            }
        }
    }

    /** The Supabase user id only: no email or name. */
    fun identify(userId: String) {
        if (sentryOn) Sentry.setUser(User().apply { id = userId })
    }

    fun reset() {
        if (sentryOn) Sentry.setUser(null)
    }

    // events

    fun capture(event: String, properties: Map<String, Any> = emptyMap()) {
        if (BuildConfig.DEBUG) Log.d("Telemetry", "$event $properties")
    }

    /** A screen shown: `$screen` with a name from the contract's screen list (never ids). */
    fun screen(name: String) = capture("\$screen", mapOf("\$screen_name" to name))

    /** A failure the app recovered from but that shouldn't happen. */
    fun error(error: Throwable, area: String) {
        if (!sentryOn || error is CancellationException) return
        Sentry.captureException(error) { it.setTag("area", area) }
    }

    // opt-out

    fun setSharing(on: Boolean) {
        if (on == sharing) return
        if (on) {
            prefs.edit().putBoolean(OPT_OUT_KEY, false).apply()
            start(T1App.instance)
            T1App.supabase.auth.currentUserOrNull()?.id?.let { identify(it) }
        } else {
            capture("analytics_opted_out")
            if (sentryOn) Sentry.close()
            sentryOn = false
            prefs.edit().putBoolean(OPT_OUT_KEY, true).apply()
        }
    }

    // scrubbing: PostgREST filters put row ids in query strings (`?event_id=eq.…`)

    internal fun stripQuery(url: String): String = url.substringBefore('?').substringBefore('#')

    private val queryKeys = listOf("http.query", "http.fragment")

    private fun scrubData(data: MutableMap<String, Any>) {
        (data["url"] as? String)?.let { data["url"] = stripQuery(it) }
        queryKeys.forEach { data.remove(it) }
    }

    internal fun scrub(crumb: Breadcrumb): Breadcrumb {
        scrubData(crumb.data)
        return crumb
    }

    internal fun scrub(event: SentryEvent): SentryEvent {
        event.request?.let { r ->
            r.url?.let { r.url = stripQuery(it) }
            r.queryString = null
            r.fragment = null
        }
        return event
    }

    internal fun scrub(tx: SentryTransaction): SentryTransaction {
        tx.request?.let { r ->
            r.url?.let { r.url = stripQuery(it) }
            r.queryString = null
            r.fragment = null
        }
        // OkHttp span descriptions are already "GET <url without query>"; the query rides in span data.
        tx.spans.forEach { span -> span.data?.let { scrubData(it) } }
        return tx
    }
}
