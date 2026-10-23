package site.table1.events.data

import android.content.Context
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import java.net.URLDecoder

/**
 * The event a web "Get the app" link carried through the Play install (contract/qr-sign-up-2026-10-23.md § Get the app):
 * the store link's `referrer` holds `t1=<the event's path>`, read once per install on first launch.
 */
object InstallReferrer {
    private const val PREFS = "t1.install"
    private const val READ = "referrerRead"
    private val EVENT = Regex("^/p/[A-Za-z0-9-]+$")

    /** What Play hands back → the table-1.site address to open; only an event's /p/<id>, anything else is ignored. */
    fun eventUrl(raw: String?): String? {
        if (raw.isNullOrEmpty()) return null
        val value = raw.split('&').firstNotNullOfOrNull { pair ->
            pair.split('=', limit = 2).takeIf { it.size == 2 && it[0] == "t1" }?.get(1)
        } ?: return null
        val path = runCatching { URLDecoder.decode(value, "UTF-8") }.getOrNull() ?: return null
        return if (EVENT.matches(path)) "https://table-1.site$path" else null
    }

    /** Once per install: asks Play for the referrer and hands over the event address it carried, if any. */
    fun readOnce(context: Context, onEvent: (String) -> Unit) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(READ, false)) return
        val client = InstallReferrerClient.newBuilder(context).build()
        runCatching {
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(code: Int) {
                    when (code) {
                        InstallReferrerClient.InstallReferrerResponse.OK -> {
                            val raw = runCatching { client.installReferrer.installReferrer }.getOrNull()
                            prefs.edit().putBoolean(READ, true).apply()
                            eventUrl(raw)?.let(onEvent)
                        }
                        // Play is busy or updating: try again next launch.
                        InstallReferrerClient.InstallReferrerResponse.SERVICE_UNAVAILABLE -> Unit
                        // Not installed from Play (sideloaded, emulator without Play): nothing will ever come.
                        else -> prefs.edit().putBoolean(READ, true).apply()
                    }
                    runCatching { client.endConnection() }
                }

                override fun onInstallReferrerServiceDisconnected() = Unit
            })
        }
    }
}
