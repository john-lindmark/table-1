package site.table1.events.util

import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * The error that flashed on opening the Android app: calls made while supabase-kt was still reloading the session went
 * out as anon or with the expired token and came back 401 (contract/android-errors-2026-11-14.md § The launch flash).
 */
class FreshTokenTest {
    private val anon = jwt(4_000_000_000L, "anon")
    private val now = System.currentTimeMillis() / 1000

    private fun jwt(exp: Long, role: String = "authenticated"): String {
        val enc = Base64.getUrlEncoder().withoutPadding()
        val head = enc.encodeToString("""{"alg":"HS256"}""".toByteArray())
        val body = enc.encodeToString("""{"sub":"u","role":"$role","exp":$exp}""".toByteArray())
        return "$head.$body.sig"
    }

    private class FakeSource(var starting: Boolean, var token: String?, val refreshed: String?) : FreshToken.Source {
        var refreshes = 0
        override fun starting() = starting
        override fun current() = token
        override suspend fun settled() { starting = false }
        override suspend fun fresh(spent: String): String? { refreshes++; token = refreshed; return refreshed }
    }

    /** Runs one call through the interceptor; the "server" answers [answer] for each Authorization it sees. */
    private fun call(source: FreshToken.Source, bearer: String, path: String = "/rest/v1/rpc/events_home",
                     answer: (String) -> Pair<Int, String> = { 200 to "{}" }): Pair<Response, List<String>> {
        val seen = mutableListOf<String>()
        val server = Interceptor { chain ->
            val auth = chain.request().header("Authorization")!!.removePrefix("Bearer ")
            seen += auth
            val (code, body) = answer(auth)
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(code).message("x")
                .body(body.toResponseBody("application/json".toMediaType())).build()
        }
        val client = OkHttpClient.Builder().addInterceptor(FreshToken(anon, source)).addInterceptor(server).build()
        val r = client.newCall(Request.Builder().url("https://x.supabase.co$path").header("Authorization", "Bearer $bearer").build()).execute()
        return r to seen
    }

    @Test
    fun readsExpiry() {
        assertEquals(1794682206L, FreshToken.expiry(jwt(1794682206L)))
        assertNull(FreshToken.expiry("not-a-jwt"))
        assertTrue(FreshToken.isSpent(jwt(now + 5), now))
        assertFalse(FreshToken.isSpent(jwt(now + 600), now))
        assertFalse(FreshToken.isSpent("not-a-jwt", now))
    }

    @Test
    fun plans() {
        assertEquals(FreshToken.Plan.AWAIT_START, FreshToken.plan(anon, anon, now, starting = true))
        assertEquals(FreshToken.Plan.SEND, FreshToken.plan(anon, anon, now, starting = false))
        assertEquals(FreshToken.Plan.REFRESH, FreshToken.plan(jwt(now - 60), anon, now, starting = false))
        assertEquals(FreshToken.Plan.SEND, FreshToken.plan(jwt(now + 3600), anon, now, starting = true))
        assertTrue(FreshToken.covers("/rest/v1/rpc/event_bundle"))
        assertTrue(FreshToken.covers("/functions/v1/deck-finder"))
        assertFalse(FreshToken.covers("/auth/v1/token"))
        assertFalse(FreshToken.covers("/realtime/v1/websocket"))
    }

    @Test
    fun aCallWhileTheSessionLoadsWaitsForItsToken() {
        val user = jwt(now + 3600)
        val (r, seen) = call(FakeSource(starting = true, token = user, refreshed = null), anon)
        assertEquals(200, r.code)
        assertEquals(listOf(user), seen)
    }

    @Test
    fun signedOutCallsGoAsAnon() {
        val (_, seen) = call(FakeSource(starting = false, token = null, refreshed = null), anon)
        assertEquals(listOf(anon), seen)
    }

    @Test
    fun anExpiredTokenIsRefreshedBeforeTheCall() {
        val old = jwt(now - 60)
        val new = jwt(now + 3600)
        val source = FakeSource(starting = false, token = old, refreshed = new)
        val (r, seen) = call(source, old)
        assertEquals(200, r.code)
        assertEquals(listOf(new), seen)
        assertEquals(1, source.refreshes)
    }

    @Test
    fun aJwtExpiredAnswerIsRefreshedAndSentOnce() {
        val old = jwt(now + 3600) // the phone's clock thinks it's fine
        val new = jwt(now + 7200)
        val source = FakeSource(starting = false, token = old, refreshed = new)
        val (r, seen) = call(source, old) { a -> if (a == old) 401 to """{"code":"PGRST301","message":"JWT expired"}""" else 200 to "{}" }
        assertEquals(200, r.code)
        assertEquals(listOf(old, new), seen)
    }

    @Test
    fun otherRefusalsAreNotRetried() {
        val user = jwt(now + 3600)
        val source = FakeSource(starting = false, token = user, refreshed = jwt(now + 7200))
        val (r, seen) = call(source, user) { 403 to """{"code":"42501","message":"That event isn't available"}""" }
        assertEquals(403, r.code)
        assertEquals(1, seen.size)
        assertEquals(0, source.refreshes)
    }

    @Test
    fun aFailedRefreshSendsTheCallAsItWas() {
        val old = jwt(now - 60)
        val (r, seen) = call(FakeSource(starting = false, token = old, refreshed = null), old)
        assertEquals(200, r.code)
        assertEquals(listOf(old), seen)
    }

    @Test
    fun authCallsPassUntouched() {
        val old = jwt(now - 60)
        val source = FakeSource(starting = true, token = null, refreshed = jwt(now + 3600))
        val (_, seen) = call(source, old, path = "/auth/v1/token")
        assertEquals(listOf(old), seen)
        assertEquals(0, source.refreshes)
    }
}
