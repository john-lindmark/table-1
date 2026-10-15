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
import site.table1.events.auth.SignIn
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Logo
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1

private enum class Step { Providers, Email, Code }

private val EMAIL = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")

/**
 * The mark, full-bleed, over the actions. Matches the "Sign in" frames in the Figma file.
 * Email is two steps under the mark: the address, then the code (or tap the link in the email).
 */
@Composable
fun SignInScreen() {
    val context: Context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var step by remember { mutableStateOf(Step.Providers) }
    var email by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    // Supabase sends at most one email a minute per address.
    var resendAt by remember { mutableLongStateOf(0L) }
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

    fun send() = run("email", "Couldn't send the email. Check the address and try again in a minute.") {
        SignIn.sendEmailCode(address)
        resendAt = System.currentTimeMillis() + 60_000
        now = System.currentTimeMillis()
        step = Step.Code
    }

    Column(Modifier.fillMaxSize().background(T1.bg).imePadding(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Box(
            Modifier.weight(1f).fillMaxWidth().background(T1.surface).statusBarsPadding().padding(top = 40.dp),
            contentAlignment = Alignment.Center,
        ) { T1Logo(Modifier.fillMaxWidth()) }
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
                Notice("We sent a link and a code to $address. Tap the link on this phone, or enter the code.")
                Box(Modifier.background(T1.surface).padding(16.dp)) {
                    T1TextField(code, { code = it.filter(Char::isDigit).take(10) }, label = "Code", placeholder = "000000",
                        keyboardType = KeyboardType.NumberPassword)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Change email") { code = ""; go(Step.Email) }
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
fun NameScreen() {
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
                    } finally {
                        busy = false
                    }
                }
            }
        }
    }
}
