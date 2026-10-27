package site.table1.events.ui.screens

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.credentials.exceptions.GetCredentialCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import site.table1.events.auth.EmailSignIn
import site.table1.events.auth.SignIn
import site.table1.events.data.JoinLink
import site.table1.events.data.JoinPreview
import site.table1.events.data.Repo
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Logo
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

private enum class Step { Providers, Email, Code }

private val EMAIL = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")

/**
 * The mark, full-bleed, over the actions. Matches the "Sign in" frames in the Figma file.
 * Email is two steps under the mark: the address, then the code (or tap the link in the email).
 */
@Composable
fun SignInScreen(join: JoinLink? = null) {
    val context: Context = LocalContext.current
    val scope = rememberCoroutineScope()
    // Back from the mail app (or restarted meanwhile): the code step for the address a code just went to.
    val restored = remember { EmailSignIn.load() }
    var busy by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var step by remember { mutableStateOf(if (restored != null) Step.Code else Step.Providers) }
    var email by remember { mutableStateOf(restored?.email ?: "") }
    var code by remember { mutableStateOf("") }
    // Supabase sends at most one email a minute per address.
    var resendAt by remember { mutableLongStateOf(restored?.resendAt ?: 0L) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val address = email.trim().lowercase()

    LaunchedEffect(step, resendAt) {
        while (step == Step.Code && now < resendAt) {
            delay(1000)
            now = System.currentTimeMillis()
        }
    }

    fun run(which: String, message: String = "Sign-in failed. Try again.", block: suspend () -> Unit) {
        busy = which
        error = null
        scope.launch {
            try {
                block()
            } catch (e: GetCredentialCancellationException) {
                // Closed the Google account sheet: no error.
            } catch (e: Exception) {
                error = message
                Telemetry.error(e, "sign_in")
            } finally {
                busy = null
            }
        }
    }

    fun go(next: Step) {
        error = null
        SignIn.emailLinkError = null
        step = next
    }

    fun codeSent(p: EmailSignIn.Pending) {
        EmailSignIn.save(p)
        resendAt = p.resendAt
        now = System.currentTimeMillis()
        error = null
        step = Step.Code
    }

    /** Send and Resend both land here; one send at a time. */
    fun send() {
        if (busy != null) return
        busy = "email"
        error = null
        scope.launch {
            try {
                SignIn.sendEmailCode(address)
                codeSent(EmailSignIn.pending(address, System.currentTimeMillis()))
            } catch (e: Exception) {
                when (val outcome = EmailSignIn.outcome(e)) {
                    is EmailSignIn.SendOutcome.AlreadySent -> {
                        // The minute per address: a code went out moments ago, so that's the step to be on.
                        Telemetry.capture("sign_in_failed", mapOf("method" to "email_send", "reason" to "already_sent"))
                        codeSent(EmailSignIn.pending(address, System.currentTimeMillis(), outcome.wait))
                    }
                    EmailSignIn.SendOutcome.TooMany -> {
                        Telemetry.capture("sign_in_failed", mapOf("method" to "email_send", "reason" to "too_many"))
                        error = "Too many sign-in emails right now. Wait a few minutes, or continue with Apple or Google."
                    }
                    EmailSignIn.SendOutcome.Failed -> {
                        Telemetry.capture("sign_in_failed", mapOf("method" to "email_send", "reason" to "error"))
                        Telemetry.error(e, "sign_in")
                        error = "Couldn't send the email. Check the address and try again."
                    }
                }
            } finally {
                busy = null
            }
        }
    }

    Column(Modifier.fillMaxSize().background(T1.bg).imePadding(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Box(
            Modifier.weight(1f).fillMaxWidth().background(T1.surface).statusBarsPadding().padding(top = 40.dp),
            contentAlignment = Alignment.Center,
        ) { T1Logo(Modifier.fillMaxWidth()) }
        join?.let { JoinHeader(it) } ?: site.table1.events.ui.PendingSignUp.page?.let { SignUpHeader(it) }
        (error ?: SignIn.emailLinkError)?.let { Notice(it, error = true) }
        when (step) {
            Step.Providers -> {
                BigAction("Continue with Apple", busy = busy == "apple", enabled = busy == null) { run("apple") { SignIn.apple() } }
                if (SignIn.googleConfigured) {
                    BigAction("Continue with Google", busy = busy == "google", enabled = busy == null, accent = true) {
                        run("google") { SignIn.google(context) }
                    }
                }
                Box(
                    Modifier.fillMaxWidth().background(T1.surface).clickable(enabled = busy == null) { go(Step.Email) }
                        .navigationBarsPadding().padding(vertical = 26.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("CONTINUE WITH EMAIL", color = T1.text, fontFamily = T1.mono, fontWeight = FontWeight.Bold,
                        fontSize = 16.sp, letterSpacing = 5.sp)
                }
            }
            Step.Email -> {
                Box(Modifier.background(T1.surface).padding(16.dp)) {
                    T1TextField(email, { email = it }, label = "Email", placeholder = "name@example.com", keyboardType = KeyboardType.Email)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) { Ghost("Back") { go(Step.Providers) } }
                Box(Modifier.navigationBarsPadding()) {
                    BigAction("Send code", enabled = EMAIL.matches(address), busy = busy == "email", accent = true) { send() }
                }
            }
            Step.Code -> {
                val wait = ((resendAt - now + 999) / 1000).coerceAtLeast(0)
                Notice("We sent a link and a code to $address. Tap the link on this phone, or enter the code. Not there? Check spam.")
                Box(Modifier.background(T1.surface).padding(16.dp)) {
                    T1TextField(code, { code = it.filter(Char::isDigit).take(10) }, label = "Code", placeholder = "000000",
                        keyboardType = KeyboardType.NumberPassword)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Change email") { code = ""; EmailSignIn.clear(); go(Step.Email) }
                    Ghost(if (wait > 0) "Resend in ${wait}s" else "Resend", enabled = wait == 0L && busy == null) { send() }
                }
                Box(Modifier.navigationBarsPadding()) {
                    BigAction("Sign in", enabled = code.length >= 6, busy = busy == "email", accent = true) {
                        run("email", "That code didn't work. Check it, or send a new one.") { SignIn.verifyEmailCode(address, code) }
                    }
                }
            }
        }
    }
}

/** New email accounts: first and last name, both required, before the app opens. */
@Composable
fun NameScreen(join: JoinLink? = null) {
    val scope = rememberCoroutineScope()
    var first by remember { mutableStateOf("") }
    var last by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val valid = first.isNotBlank() && last.isNotBlank()

    Column(Modifier.fillMaxSize().background(T1.bg).imePadding(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Box(
            Modifier.weight(1f).fillMaxWidth().background(T1.surface).statusBarsPadding().padding(top = 40.dp),
            contentAlignment = Alignment.Center,
        ) { T1Logo(Modifier.fillMaxWidth()) }
        join?.let { JoinHeader(it, naming = true) } ?: site.table1.events.ui.PendingSignUp.page?.let { SignUpHeader(it, naming = true) }
        error?.let { Notice(it, error = true) }
        Notice("Add your name. Opponents and organizers see it on pairings and standings.")
        Column(Modifier.background(T1.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            T1TextField(first, { first = it.take(40) }, label = "First name", placeholder = "First name")
            T1TextField(last, { last = it.take(40) }, label = "Last name", placeholder = "Last name")
        }
        Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            Ghost("Sign out", enabled = !busy) { scope.launch { runCatching { SignIn.signOut() } } }
        }
        Box(Modifier.navigationBarsPadding()) {
            BigAction("Continue", enabled = valid, busy = busy, accent = true) {
                busy = true
                error = null
                scope.launch {
                    try {
                        SignIn.saveName(first, last)
                    } catch (e: Exception) {
                        error = "Couldn't save your name. Try again."
                        Telemetry.error(e, "sign_in_name")
                    } finally {
                        busy = false
                    }
                }
            }
        }
    }
}

/** A scanned join QR waiting on sign-in: which event it is, and that any way in (a new account too) takes the seat. */
@Composable
private fun JoinHeader(link: JoinLink, naming: Boolean = false) {
    var preview by remember { mutableStateOf<JoinPreview?>(null) }
    LaunchedEffect(link.code) {
        preview = Repo.joinPreview(link.code)
        if (!naming) Telemetry.capture("join_prompt_viewed", mapOf("event" to (preview != null)))
    }
    Column(
        Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Label("Joining")
        Text(preview?.title ?: "Event ${link.code.uppercase()}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        preview?.let { Text(it.facts, color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp) }
        Text(
            if (naming) "Add your name and you're in."
            else "New to Table 1? Any option below makes your account. You're seated as soon as you're in.",
            color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp, lineHeight = 18.sp,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}
