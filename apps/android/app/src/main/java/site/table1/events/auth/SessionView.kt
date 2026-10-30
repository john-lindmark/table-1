package site.table1.events.auth

import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession

/**
 * What the app shows for supabase-kt's session status. A refresh that fails offline or on a 5xx is RefreshFailure:
 * the library keeps the session saved and retries every few seconds (it clears it only when the server refuses the
 * refresh token, which is NotAuthenticated). AppRoot drew the sign-in screen for it, so a dropped connection looked
 * like being signed out until the retry landed (John's Play install, 2026-10-30). Now the app stays up on the session
 * it last had, or the one saved on the device after a cold start offline.
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
        SessionStatus.Initializing -> Shown.Starting
    }
}
