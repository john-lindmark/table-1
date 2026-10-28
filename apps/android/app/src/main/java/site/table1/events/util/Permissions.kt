package site.table1.events.util

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import site.table1.events.T1App

/** On before the step if already granted; Android can't tell never-asked from refused, so the rest start unasked. */
enum class PermissionState { Unasked, On, Off }

/**
 * The permissions step after sign-in (contract/permissions-onboarding-2026-10-28.md): why notifications and location
 * help, then the system dialogs only when the player taps Turn on. Skipped, it never comes back on its own.
 */
object PermissionsStep {
    /** Debug builds: `--ez permissionsDemo true` shows the step whatever was answered before. */
    var demo = false

    /** Once per device, and only while there's something left to ask. */
    fun shouldShow(seen: Boolean, notifications: PermissionState, location: PermissionState): Boolean =
        !seen && (notifications == PermissionState.Unasked || location == PermissionState.Unasked)

    private val prefs get() = T1App.instance.getSharedPreferences("onboarding", Context.MODE_PRIVATE)
    var seen: Boolean
        get() = prefs.getBoolean("permissions.seen", false)
        set(value) = prefs.edit().putBoolean("permissions.seen", value).apply()

    /** POST_NOTIFICATIONS is asked for from Android 13; before that notifications are on unless turned off in settings. */
    val notificationPermissions: Array<String> =
        if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.POST_NOTIFICATIONS) else emptyArray()
    val locationPermissions = arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)

    fun notifications(context: Context) = state(context, notificationPermissions)
    fun location(context: Context) = state(context, locationPermissions)
    fun locationAllowed(context: Context) = location(context) == PermissionState.On

    private fun state(context: Context, permissions: Array<String>) =
        if (permissions.isEmpty() || permissions.any { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) PermissionState.On
        else PermissionState.Unasked

    fun needed(context: Context) = demo || shouldShow(seen, notifications(context), location(context))
}
