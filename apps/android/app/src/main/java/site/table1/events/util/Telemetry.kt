package site.table1.events.util

import android.util.Log
import site.table1.events.BuildConfig

/**
 * Product analytics (contract/telemetry-2026-10-15.md). Android's PostHog/Sentry wiring isn't built yet (iOS → web →
 * Android); call sites go in now with the contract's event names, and this logs them in Debug until the SDK lands.
 * Properties are counts, enums and booleans only: never names, free text, join codes or row ids.
 */
object Telemetry {
    fun capture(event: String, properties: Map<String, Any> = emptyMap()) {
        if (BuildConfig.DEBUG) Log.d("Telemetry", "$event $properties")
    }

    /** A screen shown: `$screen` with a name from the contract's screen list (never ids). */
    fun screen(name: String) = capture("\$screen", mapOf("\$screen_name" to name))
}
