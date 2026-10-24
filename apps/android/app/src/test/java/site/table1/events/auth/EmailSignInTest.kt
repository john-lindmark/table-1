package site.table1.events.auth

import io.github.jan.supabase.auth.exception.AuthRestException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/* A refused email send and the kept code step (contract/email-sign-in-2026-10-15.md § Already sent) against
   testdata/email-sign-in/cases.json (also iOS EmailSignInTests and web emailSignIn.test.ts). */
class EmailSignInTest {
    @Serializable private data class Send(val name: String, val status: Int, val code: String, val message: String, val outcome: String, val wait: Int)
    @Serializable private data class Restore(
        val name: String, val email: String, val sent_at: Long, val resend_at: Long, val now: Long,
        val restored: Boolean, val resend_at_out: Long,
    )
    @Serializable private data class Cases(val send: List<Send>, val restore: List<Restore>)

    private val cases = Json { ignoreUnknownKeys = true }.decodeFromString<Cases>(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/email-sign-in") }
            .first { it.isDirectory }, "cases.json").readText(),
    )

    @Test fun sendOutcomes() {
        assertTrue(cases.send.size > 5)
        for (c in cases.send) {
            val want = when (c.outcome) {
                "already_sent" -> EmailSignIn.SendOutcome.AlreadySent(c.wait)
                "too_many" -> EmailSignIn.SendOutcome.TooMany
                else -> EmailSignIn.SendOutcome.Failed
            }
            assertEquals(c.name, want, EmailSignIn.outcome(c.status, c.code, c.message))
        }
    }

    @Test fun restore() {
        for (c in cases.restore) {
            val out = EmailSignIn.restore(EmailSignIn.Pending(c.email, c.sent_at * 1000, c.resend_at * 1000), c.now * 1000)
            assertEquals(c.name, c.restored, out != null)
            if (out != null) assertEquals(c.name, c.resend_at_out * 1000, out.resendAt)
        }
    }

    @Test fun readsAuthRestException() {
        val e = AuthRestException("over_email_send_rate_limit", "For security purposes, you can only request this after 19 seconds.", 429)
        assertEquals(EmailSignIn.SendOutcome.AlreadySent(19), EmailSignIn.outcome(e))
        assertEquals(EmailSignIn.SendOutcome.Failed, EmailSignIn.outcome(IllegalStateException("offline")))
    }

    @Test fun alreadySentRestoresItsCountdown() {
        val p = EmailSignIn.pending("a@b.co", 5_000_000, 19)
        assertEquals(5_019_000L, p.resendAt)
        assertEquals(p.resendAt, EmailSignIn.restore(p, 5_005_000)?.resendAt)
    }
}
