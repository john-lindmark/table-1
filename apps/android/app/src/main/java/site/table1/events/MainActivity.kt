package site.table1.events

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import io.github.jan.supabase.auth.handleDeeplinks
import kotlinx.coroutines.launch
import site.table1.events.auth.SignIn
import site.table1.events.data.JoinLink
import site.table1.events.ui.AppRoot
import site.table1.events.ui.theme.Table1Theme

class MainActivity : ComponentActivity() {
    private var pendingJoin by mutableStateOf<JoinLink?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handle(intent)
        setContent {
            Table1Theme {
                AppRoot(pendingJoin = pendingJoin, onJoinConsumed = { pendingJoin = null })
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        // Sign in with Apple comes back as table1://auth-callback#...; supabase-kt finishes the session.
        T1App.supabase.handleDeeplinks(intent)
        // The sign-in email's button (https://table-1.site/auth/confirm?token_hash=…).
        SignIn.emailLinkHash(intent.data)?.let { hash ->
            lifecycleScope.launch { SignIn.verifyEmailLink(hash) }
            return
        }
        // The owner's QR (https://table-1.site/j/<code>?s=<secret>) opened from the camera or a link.
        JoinLink.parse(intent.dataString)?.let { pendingJoin = it }
    }
}
