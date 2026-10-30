package site.table1.events.auth

import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession

/**
 * What the app shows for supabase-kt's session status. A refresh that fails offline or on a 5xx is RefreshFailure:
 * the library keeps the session saved and retries every few seconds (it clears it only when the server refuses the
 * refresh token, which is NotAuthenticated). AppRoot drew the sign-in screen for it, so a dropped connection looked
 * like being signed out until the retry landed (John's Play install, 2026-10-30). Now the app stays up on the session
 * it last had, or the one saved on the device after a cold start offline.
 *
 * Initializing comes back on every trip to the background too: supabase-kt resets the status when the app stops and
 * reloads the session from storage when it starts. Drawing the start screen for it took the signed-in screens out, so
 * every return opened on Events (John, 2026-10-30). With a session kept, it stays signed in on the screen you left.
 */
object SessionView {
    sealed interface Shown {
        data object Starting : Shown
        data object SignedOut : Shown
        data class SignedIn(val session: UserSession) : Shown
    }

    /** [kept]: the last signed-in session (null until read); [keptRead]: the device's saved session has been looked for. */
    fun shown(status: SessionStatus, kept: UserSession?, keptRead: Boolean): Shown = when (status) {
        is SessionStatus.Authenticated -> Shown.SignedIn(status.session)
        is SessionStatus.RefreshFailure -> when {
            kept != null -> Shown.SignedIn(kept)
            keptRead -> Shown.SignedOut
            else -> Shown.Starting
        }
        is SessionStatus.NotAuthenticated -> Shown.SignedOut
        SessionStatus.Initializing -> kept?.let { Shown.SignedIn(it) } ?: Shown.Starting
    }

    /** Back from the background after this long, the app opens on Events again; sooner, it stays where it was. */
    const val IDLE_RESET_MS = 30 * 60 * 1000L

    /** [stoppedAt]/[now]: SystemClock.elapsedRealtime() when the app went to the background and when it came back. */
    fun backToEvents(stoppedAt: Long?, now: Long): Boolean = stoppedAt != null && now - stoppedAt >= IDLE_RESET_MS
}
