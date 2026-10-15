package site.table1.events.ui.screens

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import site.table1.events.auth.SignIn
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Logo
import site.table1.events.ui.theme.T1

/** The mark, full-bleed, over the actions. Matches the "Sign in" frames in the Figma file. */
@Composable
fun SignInScreen() {
    val context: Context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    fun run(which: String, block: suspend () -> Unit) {
        busy = which
        error = null
        scope.launch {
            try {
                block()
            } catch (e: Exception) {
                error = "Sign-in failed. Try again."
            } finally {
                busy = null
            }
        }
    }

    Column(Modifier.fillMaxSize().background(T1.bg), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Box(
            Modifier.weight(1f).fillMaxWidth().background(T1.surface).statusBarsPadding().padding(top = 40.dp),
            contentAlignment = Alignment.Center,
        ) { T1Logo(Modifier.fillMaxWidth()) }
        error?.let { Notice(it, error = true) }
        BigAction("Continue with Apple", busy = busy == "apple", enabled = busy == null) { run("apple") { SignIn.apple() } }
        Box(Modifier.navigationBarsPadding()) {
            BigAction("Continue with Google", busy = busy == "google", enabled = busy == null, accent = true) {
                run("google") { SignIn.google(context) }
            }
        }
    }
}
