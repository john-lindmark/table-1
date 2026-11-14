package site.table1.events.util

import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.status.SessionStatus
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Every call to the server leaves with a usable access token (contract/android-errors-2026-11-14.md § The launch flash).
 *
 * supabase-kt resets its session to Initializing on every trip to the background and reloads it on the way back, then
 * refreshes an expired token in the background. A screen loading in that moment sent the anon key (no session yet) or
 * the expired token, the server answered 401, and the screen showed an error until its next load: the error that
 * flashed on opening the app (live logs 2026-11-14: events_home, events_followed, people, friends_list…).
 *
 * This interceptor holds such a call until the session has settled and its token is fresh (refreshing it once itself
 * when supabase-kt hasn't), and retries once on a "JWT expired" answer (a phone clock running behind). Auth's own calls
 * and Realtime's socket pass untouched. Waits are bounded ([WAIT_MS]); a call that still has no token goes as it was.
 */
class FreshToken(private val anonKey: String, private val source: Source) : Interceptor {

    /** The session, behind an interface so the rules can be tested without supabase-kt. */
    interface Source {
        /** Still loading the saved session (supabase-kt's Initializing). */
        fun starting(): Boolean
        /** The current access token, if signed in. */
        fun current(): String?
        /** Waits (bounded by the caller) until the session isn't loading any more. */
        suspend fun settled()
        /** A token other than [spent] and not about to expire: supabase-kt's, else refreshed here. Null if none. */
        suspend fun fresh(spent: String): String?
    }

    enum class Plan { SEND, AWAIT_START, REFRESH }

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (!covers(request.url.encodedPath)) return chain.proceed(request)
        val bearer = request.header("Authorization")?.removePrefix("Bearer ")?.trim() ?: return chain.proceed(request)
        val now = System.currentTimeMillis() / 1000
        val token = when (plan(bearer, anonKey, now, source.starting())) {
            Plan.SEND -> bearer
            Plan.AWAIT_START -> runBlocking {
                withTimeoutOrNull(WAIT_MS) { source.settled() }
                val t = source.current()
                if (t != null && isSpent(t, now)) withTimeoutOrNull(WAIT_MS) { source.fresh(t) } ?: t else t
            } ?: bearer
            Plan.REFRESH -> runBlocking { withTimeoutOrNull(WAIT_MS) { source.fresh(bearer) } } ?: bearer
        }
        val sent = if (token == bearer) request else request.newBuilder().header("Authorization", "Bearer $token").build()
        val response = chain.proceed(sent)
        if (token == anonKey || !expiredReply(response.code, response.peekBody(2048).string())) return response
        // The server says the token is spent though the phone thought otherwise: refresh once and send it again
        // (PostgREST refuses before running anything, so the call is safe to repeat).
        val again = runBlocking { withTimeoutOrNull(WAIT_MS) { source.fresh(token) } } ?: return response
        response.close()
        return chain.proceed(sent.newBuilder().header("Authorization", "Bearer $again").build())
    }

    companion object {
        /** Seconds before its expiry a token counts as spent (a call in flight shouldn't land after it). */
        const val MARGIN_S = 15L
        /** Longest a call waits for the session. */
        const val WAIT_MS = 10_000L

        /** The server's data calls; Auth's own calls (the refresh itself) and Realtime's socket aren't held. */
        fun covers(path: String): Boolean = !path.startsWith("/auth/v1/") && !path.startsWith("/realtime/v1/")

        /** What to do with a call carrying [bearer]. */
        fun plan(bearer: String, anonKey: String, nowS: Long, starting: Boolean): Plan = when {
            bearer == anonKey -> if (starting) Plan.AWAIT_START else Plan.SEND
            isSpent(bearer, nowS) -> Plan.REFRESH
            else -> Plan.SEND
        }

        /** The token's `exp` (seconds), or null when it isn't a readable JWT. */
        fun expiry(jwt: String): Long? = runCatching {
            val payload = jwt.split('.').getOrNull(1) ?: return null
            val bytes = java.util.Base64.getUrlDecoder().decode(payload)
            Json.parseToJsonElement(String(bytes)).jsonObject["exp"]?.jsonPrimitive?.longOrNull
        }.getOrNull()

        fun isSpent(jwt: String, nowS: Long): Boolean = expiry(jwt)?.let { it <= nowS + MARGIN_S } ?: false

        /** PostgREST's answer to an expired token. */
        fun expiredReply(code: Int, body: String): Boolean = code == 401 && body.contains("JWT expired", ignoreCase = true)

        /** The app's session as a [Source]. */
        fun source(auth: () -> Auth): Source = object : Source {
            private val lock = Mutex()
            override fun starting() = auth().sessionStatus.value is SessionStatus.Initializing
            override fun current() = auth().currentAccessTokenOrNull()
            override suspend fun settled() { auth().sessionStatus.first { it !is SessionStatus.Initializing } }
            override suspend fun fresh(spent: String): String? = lock.withLock {
                val now = System.currentTimeMillis() / 1000
                fun usable(t: String?) = t?.takeIf { it != spent && !isSpent(it, now) }
                usable(current())?.let { return it }
                // supabase-kt refreshes a spent token on its own when the app comes back: give it a moment first.
                withTimeoutOrNull(3_000) {
                    auth().sessionStatus.first { s -> s is SessionStatus.Authenticated && usable(s.session.accessToken) != null }
                }?.let { return usable(current()) }
                try {
                    auth().refreshCurrentSession()
                } catch (e: Exception) {
                    e.rethrowIfCancelled()
                }
                usable(current())
            }
        }
    }
}
