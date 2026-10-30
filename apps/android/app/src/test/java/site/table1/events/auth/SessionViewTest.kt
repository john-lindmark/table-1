package site.table1.events.auth

import io.github.jan.supabase.auth.status.RefreshFailureCause
import io.github.jan.supabase.auth.status.SessionSource
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import org.junit.Assert.assertEquals
import org.junit.Test
import site.table1.events.auth.SessionView.Shown

/* A refresh that fails offline drew the sign-in screen until the retry landed (2026-10-30). */
class SessionViewTest {
    private val old = UserSession(accessToken = "old", refreshToken = "r1", expiresIn = 3600, tokenType = "bearer", user = null)
    private val fresh = UserSession(accessToken = "new", refreshToken = "r2", expiresIn = 3600, tokenType = "bearer", user = null)
    private val offline = SessionStatus.RefreshFailure(RefreshFailureCause.NetworkError(java.io.IOException("no network")))

    @Test fun failedRefreshStaysSignedIn() {
        assertEquals(Shown.SignedIn(old), SessionView.shown(offline, kept = old, keptRead = true))
    }

    @Test fun coldStartOfflineWaitsForTheSavedSession() {
        assertEquals(Shown.Starting, SessionView.shown(offline, kept = null, keptRead = false))
        assertEquals(Shown.SignedIn(old), SessionView.shown(offline, kept = old, keptRead = true))
        // Nothing saved (shouldn't happen with a refresh to retry): sign in.
        assertEquals(Shown.SignedOut, SessionView.shown(offline, kept = null, keptRead = true))
    }

    @Test fun signedInShowsTheCurrentSession() {
        assertEquals(Shown.SignedIn(fresh), SessionView.shown(SessionStatus.Authenticated(fresh, SessionSource.Unknown), kept = old, keptRead = true))
    }

    @Test fun realSignOutsStillSignOut() {
        // A refused refresh token or a sign-out is NotAuthenticated, whatever was kept.
        assertEquals(Shown.SignedOut, SessionView.shown(SessionStatus.NotAuthenticated(isSignOut = false), kept = old, keptRead = true))
        assertEquals(Shown.SignedOut, SessionView.shown(SessionStatus.NotAuthenticated(isSignOut = true), kept = null, keptRead = true))
        assertEquals(Shown.Starting, SessionView.shown(SessionStatus.Initializing, kept = null, keptRead = false))
    }

    /* Every return from the background drew the start screen and reopened on Events (2026-10-30). */
    @Test fun returningFromTheBackgroundStaysSignedIn() {
        // supabase-kt resets to Initializing when the app stops and reloads the session when it starts.
        assertEquals(Shown.SignedIn(old), SessionView.shown(SessionStatus.Initializing, kept = old, keptRead = true))
        assertEquals(Shown.SignedIn(fresh), SessionView.shown(SessionStatus.Authenticated(fresh, SessionSource.Storage), kept = old, keptRead = true))
    }

    @Test fun backToEventsOnlyAfterAnIdle() {
        val min = 60_000L
        assertEquals(false, SessionView.backToEvents(stoppedAt = null, now = 100 * min))
        assertEquals(false, SessionView.backToEvents(stoppedAt = 10 * min, now = 11 * min))
        assertEquals(false, SessionView.backToEvents(stoppedAt = 10 * min, now = 39 * min + 59_000))
        assertEquals(true, SessionView.backToEvents(stoppedAt = 10 * min, now = 40 * min))
        assertEquals(true, SessionView.backToEvents(stoppedAt = 10 * min, now = 300 * min))
    }
}
