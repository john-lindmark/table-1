package site.table1.events.util

import io.github.jan.supabase.exceptions.RestException

/**
 * PostgREST refused the call because the access token had run out. On a return to the app supabase-kt reloads the
 * saved session and refreshes it in the background, so a call made in that moment goes out with the old token
 * (bug #30: `catalog_info` and `moderation_me` 401 "JWT expired" right after resuming).
 */
fun Throwable.isExpiredSession(): Boolean =
    this is RestException && statusCode == 401 && (error.contains("JWT expired", ignoreCase = true) ||
        message?.contains("JWT expired", ignoreCase = true) == true)

/**
 * Runs [block]; when it fails on an expired token, [refresh]es the session and runs it once more. A refresh that
 * fails (offline) rethrows the original error.
 */
suspend fun <T> retryOnExpiredSession(refresh: suspend () -> Unit, block: suspend () -> T): T =
    try {
        block()
    } catch (e: Exception) {
        e.rethrowIfCancelled()
        if (!e.isExpiredSession()) throw e
        try {
            refresh()
        } catch (r: Exception) {
            r.rethrowIfCancelled()
            throw e
        }
        block()
    }
