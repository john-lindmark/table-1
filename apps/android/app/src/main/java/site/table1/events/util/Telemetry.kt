package site.table1.events.util

import android.app.NotificationManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.util.Log
import com.posthog.PersonProfiles
import com.posthog.PostHog
import com.posthog.android.PostHogAndroid
import com.posthog.android.PostHogAndroidConfig
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
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.Interceptor
import site.table1.events.BuildConfig
import site.table1.events.T1App
import site.table1.events.widgets.MatchWidgetReceiver
import site.table1.events.widgets.NextEventWidgetReceiver
import site.table1.events.widgets.MetaWidgetReceiver
import site.table1.events.widgets.MatchupGridWidgetReceiver
import site.table1.events.widgets.ArchetypeWidgetReceiver
import site.table1.events.widgets.ValueWidgetReceiver

/**
 * Crash reporting (Sentry) and product analytics, per contract/telemetry-2026-10-15.md, mirroring iOS Telemetry.swift.
 * Sentry is off when `T1_SENTRY_DSN` is empty, PostHog when `T1_POSTHOG_KEY` is; both are off in Debug unless built with
 * `-PT1_TELEMETRY=1`, and when the person turns off "Share usage and crash data" in Account.
 * Properties are counts, enums and booleans only: never names, free text, join codes or row ids.
 */
object Telemetry {
    private const val OPT_OUT_KEY = "telemetry.optedOut"
    private val prefs get() = T1App.instance.getSharedPreferences("telemetry", Context.MODE_PRIVATE)
    private var sentryOn = false
    private var postHogOn = false
    private var postHogSetUp = false   // PostHogAndroid.setup runs once per process; opting back in only calls optIn
    private var watchingSession = false

    val sharing: Boolean get() = !prefs.getBoolean(OPT_OUT_KEY, false)

    private val allowedInBuild get() = !BuildConfig.DEBUG || BuildConfig.TELEMETRY_IN_DEBUG
    private val environment get() = if (BuildConfig.DEBUG) "debug" else BuildConfig.RELEASE_ENVIRONMENT

    /**
     * Called first thing in Application.onCreate, before anything else can crash. On Google's Test Lab phones (the Play
     * pre-launch report) crashes still go to Sentry, as environment `test_lab`, and nothing goes to PostHog.
     */
    fun start(context: Context) {
        if (!allowedInBuild || !sharing) return
        val robot = TestLab.isTestLab(context)
        startSentry(context, robot)
        if (!robot) startPostHog(context)
        if (sentryOn || postHogOn) watchSession()
    }

    private fun startSentry(context: Context, robot: Boolean) {
        if (BuildConfig.SENTRY_DSN.isEmpty()) return
        val env = if (robot) "test_lab" else environment
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
    }

    private fun startPostHog(context: Context) {
        if (BuildConfig.POSTHOG_KEY.isEmpty()) return
        if (!postHogSetUp) {
            val config = PostHogAndroidConfig(BuildConfig.POSTHOG_KEY, BuildConfig.POSTHOG_HOST).apply {
                captureApplicationLifecycleEvents = true
                captureScreenViews = false      // named by hand with screen()
                // Opened links can carry share-link tokens and join codes; `link_opened` records the kind instead.
                captureDeepLinks = false
                captureElementInteractions = false
                captureRageClicks = false
                captureDeadClicks = false
                sessionReplay = false
                surveys = false
                // Push stays on, as on iOS: `$push_notification_opened` and the FCM push subscription. For pushes
                // we send, PostHog records the open without the title or body.
                personProfiles = PersonProfiles.IDENTIFIED_ONLY
                debug = BuildConfig.DEBUG       // logs each capture and flush to logcat
            }
            PostHogAndroid.setup(context, config)
            postHogSetUp = true
        }
        PostHog.optIn()   // clears an earlier opt-out; start() only runs while sharing is on
        PostHog.register("platform", "android")
        PostHog.register("app_version", BuildConfig.VERSION_NAME)
        PostHog.register("build", BuildConfig.VERSION_CODE.toString())
        PostHog.register("environment", environment)
        postHogOn = true
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

    /** The Supabase user id only: no email or name, in either tool. */
    fun identify(userId: String) {
        if (postHogOn) {
            PostHog.identify(
                userId,
                userProperties = mapOf("platform" to "android"),
                userPropertiesSetOnce = mapOf("first_seen_app_version" to BuildConfig.VERSION_NAME),
            )
        }
        if (sentryOn) Sentry.setUser(User().apply { id = userId })
    }

    fun reset() {
        if (postHogOn) PostHog.reset()
        if (sentryOn) Sentry.setUser(null)
    }

    // events

    fun capture(event: String, properties: Map<String, Any> = emptyMap()) {
        if (!postHogOn) {
            if (BuildConfig.DEBUG) Log.d("Telemetry", "$event $properties")
            return
        }
        PostHog.capture(event, properties = properties.ifEmpty { null })
    }

    /** A screen shown: `$screen` with a name from the contract's screen list (never ids). */
    fun screen(name: String) {
        if (!postHogOn) {
            if (BuildConfig.DEBUG) Log.d("Telemetry", "\$screen $name")
            return
        }
        PostHog.screen(name)
    }

    /** A failure the app recovered from but that shouldn't happen. */
    fun error(error: Throwable, area: String) {
        if (!sentryOn || !reports(error)) return
        Sentry.captureException(error) { it.setTag("area", area) }
    }

    /** Cancellations and failures to reach the server (offline, no DNS, timeouts) are expected, never reported
     *  (bug #39: supabase-kt wraps an offline call's IOException in HttpRequestException, which got through). */
    fun reports(error: Throwable): Boolean = error !is CancellationException && !Offline.isNetwork(error)

    // live notifications and widgets

    private const val WIDGETS_KEY = "telemetry.widgets"
    private val widgetKinds = listOf(
        NextEventWidgetReceiver::class.java to "next_event",
        ValueWidgetReceiver::class.java to "value",
        MatchWidgetReceiver::class.java to "match",
        MetaWidgetReceiver::class.java to "meta",
        MatchupGridWidgetReceiver::class.java to "matchup_grid",
        ArchetypeWidgetReceiver::class.java to "archetype",
    )

    /**
     * Super properties for the system surfaces (live notifications allowed, widgets on the home screen), plus
     * `widgets_changed` when the set of widgets differs from last time, as iOS's syncSurfaces. Run on each start of
     * MainActivity (launch and every return to the foreground).
     */
    fun syncSurfaces(context: Context) {
        if (!postHogOn) return
        PostHog.register("live_activities_enabled", liveUpdatesAllowed(context))
        val manager = AppWidgetManager.getInstance(context) ?: return
        val families = widgetKinds.flatMap { (receiver, kind) ->
            List(manager.getAppWidgetIds(ComponentName(context, receiver)).size) { kind }
        }.sorted()
        PostHog.register("widgets", families.size)
        val (key, send) = widgetsDiff(prefs.getString(WIDGETS_KEY, null), families) ?: return
        prefs.edit().putString(WIDGETS_KEY, key).apply()
        if (send) capture("widgets_changed", mapOf("count" to families.size, "families" to families))
    }

    /**
     * The key to keep when the installed [families] differ from the [stored] key (null when unchanged), and whether
     * to send `widgets_changed`: not for the first look, when it finds none.
     */
    internal fun widgetsDiff(stored: String?, families: List<String>): Pair<String, Boolean>? {
        val key = families.sorted().joinToString(",")
        if (key == stored) return null
        return key to !(stored == null && families.isEmpty())
    }

    /** Android's counterpart of "Live Activities allowed": notifications on and the live channel not turned off. */
    private fun liveUpdatesAllowed(context: Context): Boolean {
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return false
        val channel = nm.getNotificationChannel(LiveUpdates.CHANNEL)
        return channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE
    }

    // opt-out

    fun setSharing(on: Boolean) {
        if (on == sharing) return
        if (on) {
            prefs.edit().putBoolean(OPT_OUT_KEY, false).apply()
            start(T1App.instance)
            T1App.supabase.auth.currentUserOrNull()?.id?.let { identify(it) }
            syncSurfaces(T1App.instance)
        } else {
            capture("analytics_opted_out")
            if (postHogOn) { PostHog.flush(); PostHog.optOut() }
            if (sentryOn) Sentry.close()
            postHogOn = false
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
