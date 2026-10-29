package site.table1.events.util

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.BuildConfig
import site.table1.events.MainActivity
import site.table1.events.R
import site.table1.events.T1App
import site.table1.events.data.PushRoutes
import site.table1.events.data.WebLink

/**
 * Alert pushes through FCM (contract/event-night-2026-10-16.md § 4): registers this phone's token with `register_device`
 * whenever someone is signed in, removes it at sign-out, and draws each push (notify-worker sends data only). Never asks
 * for permission itself: that's the permissions step after sign-in.
 */
object Push {
    /** The push's data on the Intent a tapped notification opens. */
    const val EXTRA = "t1.push"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var registeredFor: String? = null
    private var watching = false

    /** App start: the channels, then register whenever a session is (or becomes) signed in. */
    fun start(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        PushRoutes.Channel.entries.forEach { c ->
            manager.createNotificationChannel(
                NotificationChannel(c.id, c.title, if (c.urgent) NotificationManager.IMPORTANCE_HIGH else NotificationManager.IMPORTANCE_DEFAULT)
                    .apply { description = c.description },
            )
        }
        if (watching) return
        watching = true
        scope.launch {
            T1App.supabase.auth.sessionStatus.collect { status ->
                when (status) {
                    is SessionStatus.Authenticated -> register(null)
                    is SessionStatus.NotAuthenticated -> registeredFor = null
                    else -> Unit
                }
            }
        }
    }

    /** A new token (FCM rotates them) or a sign-in: tell the server which account this phone's alerts are for. */
    fun register(newToken: String?) = scope.launch {
        if (T1App.supabase.auth.sessionStatus.value !is SessionStatus.Authenticated) return@launch
        val token = newToken ?: runCatching { FirebaseMessaging.getInstance().token.await() }.getOrNull() ?: return@launch
        if (token == registeredFor) return@launch
        runCatching {
            T1App.supabase.postgrest.rpc("register_device", buildJsonObject {
                put("p_platform", "android")
                put("p_push_token", token)
                put("p_app_version", BuildConfig.VERSION_NAME)
                put("p_env", if (BuildConfig.DEBUG) "development" else "production")
            })
        }.onSuccess { registeredFor = token }
    }

    /** Before signing out (it needs the session): this phone stops getting the old account's alerts. */
    suspend fun signOut() {
        val token = runCatching { FirebaseMessaging.getInstance().token.await() }.getOrNull() ?: return
        runCatching { T1App.supabase.postgrest.rpc("unregister_device", buildJsonObject { put("p_push_token", token) }) }
        registeredFor = null
    }

    /** The screen a tapped notification opens, read off MainActivity's Intent. */
    fun tapped(intent: Intent): WebLink? {
        val extras = intent.getBundleExtra(EXTRA) ?: return null
        intent.removeExtra(EXTRA)
        val data = extras.keySet().associateWith { extras.getString(it) ?: "" }
        Telemetry.capture("push_opened", mapOf("kind" to (data["kind"] ?: "unknown")))
        return PushRoutes.link(data)
    }

    fun show(context: Context, data: Map<String, String>) {
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return
        val kind = data["kind"] ?: return
        val tag = data["tag"] ?: kind
        val open = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(EXTRA, Bundle().apply { data.forEach { (k, v) -> putString(k, v) } })
        val tap = PendingIntent.getActivity(context, tag.hashCode(), open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val channel = PushRoutes.channel(kind)
        val body = data["body"] ?: ""
        val notification = NotificationCompat.Builder(context, channel.id)
            .setSmallIcon(R.drawable.ic_stat_t1)
            .setColor(context.getColor(R.color.t1_accent))
            .setContentTitle(data["title"] ?: "Table 1")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(if (channel.urgent) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .setGroup(data["group"])
            .setAutoCancel(true)
            .setContentIntent(tap)
            .build()
        // Same tag: a newer alert about the same thing replaces the older one.
        runCatching { manager.notify(tag, 0, notification) }
    }
}

class T1MessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        Push.register(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        Push.show(this, message.data)
    }
}
