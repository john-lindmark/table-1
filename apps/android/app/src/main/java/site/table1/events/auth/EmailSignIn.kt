package site.table1.events.auth

import android.content.Context
import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.exceptions.RestException
import site.table1.events.T1App

/**
 * What a refused email send means, and the code step kept across leaving the app
 * (contract/email-sign-in-2026-10-15.md § Already sent; cases testdata/email-sign-in/cases.json).
 */
object EmailSignIn {
    sealed interface SendOutcome {
        /** A code went out moments ago (Supabase's minute per address): show the code step, resend in [wait] s. */
        data class AlreadySent(val wait: Int) : SendOutcome
        /** The project's hourly cap or this network's request limit: no code is on its way. */
        data object TooMany : SendOutcome
        data object Failed : SendOutcome
    }

    /** A code lives an hour; Supabase sends at most one a minute per address. */
    const val CODE_LIFE_MS = 3_600_000L
    const val RESEND_GAP_MS = 60_000L

    private val SECONDS_LEFT = Regex("after (\\d+) seconds?")

    fun outcome(status: Int?, code: String?, message: String): SendOutcome {
        val limited = code == "over_email_send_rate_limit" || code == "over_request_rate_limit" || status == 429
        if (!limited) return SendOutcome.Failed
        val wait = if (code == "over_request_rate_limit") null else SECONDS_LEFT.find(message)?.groupValues?.get(1)?.toIntOrNull()
        return if (wait != null) SendOutcome.AlreadySent(wait.coerceIn(1, 60)) else SendOutcome.TooMany
    }

    fun outcome(e: Throwable): SendOutcome {
        val rest = e as? RestException ?: return SendOutcome.Failed
        val code = (rest as? AuthRestException)?.errorCode?.value ?: rest.error
        return outcome(rest.statusCode, code, listOfNotNull(rest.description, rest.message).joinToString(" "))
    }

    /**
     * App Store and Play reviewers can't read a code from our email, so this one address signs in with a fixed
     * code (its password, in John's Keychain) and no email is sent (contract § Review account).
     */
    const val REVIEW_ADDRESS = "appreview@table-1.site"

    fun isReview(email: String): Boolean = email.trim().lowercase() == REVIEW_ADDRESS

    data class Pending(val email: String, val sentAt: Long, val resendAt: Long)

    /** The saved code step if its code can still be used at [now], with Resend never before send + 60 s. */
    fun restore(saved: Pending?, now: Long): Pending? {
        if (saved == null || saved.email.isEmpty()) return null
        val age = now - saved.sentAt
        if (age < 0 || age >= CODE_LIFE_MS) return null
        return saved.copy(resendAt = maxOf(saved.resendAt, saved.sentAt + RESEND_GAP_MS))
    }

    /** After a send, or an already-sent whose code went out `60 - wait` seconds ago. */
    fun pending(email: String, now: Long, wait: Int? = null): Pending {
        val resendAt = now + (wait ?: 60) * 1000L
        return Pending(email, resendAt - RESEND_GAP_MS, resendAt)
    }

    private val prefs get() = T1App.instance.getSharedPreferences("signin", Context.MODE_PRIVATE)

    fun save(p: Pending) {
        prefs.edit().putString("email", p.email).putLong("sentAt", p.sentAt).putLong("resendAt", p.resendAt).apply()
    }

    fun load(now: Long = System.currentTimeMillis()): Pending? {
        val saved = prefs.getString("email", null)?.let { Pending(it, prefs.getLong("sentAt", 0), prefs.getLong("resendAt", 0)) }
        return restore(saved, now).also { if (it == null) clear() }
    }

    fun clear() {
        prefs.edit().clear().apply()
    }
}
