package site.table1.events.ui.screens

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import site.table1.events.auth.SignIn
import site.table1.events.data.AccountOverview
import site.table1.events.data.Repo
import site.table1.events.tracker.TrackerSettings
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigNumber
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.record
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1

/** The Account tab: lifetime record, head-to-head, settings, and the account itself. */
@Composable
fun AccountScreen(foregrounds: Int) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var overview by remember { mutableStateOf<AccountOverview?>(null) }
    var alertsOn by remember { mutableStateOf(false) }
    var showAll by remember { mutableStateOf(false) }
    var editingName by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        runCatching { Repo.accountOverview() }.onSuccess { overview = it; error = null }.onFailure { error = it.message }
        alertsOn = Repo.nearbyAlertsOn()
        TrackerSettings.refresh()
    }
    LaunchedEffect(foregrounds) { load() }

    val r = overview?.record
    val rivals = overview?.headToHead.orEmpty()
    T1Screen {
        Bar(overview?.label ?: "Account", "Account")
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            error?.let { item { Notice(it, error = true) } }
            item {
                BigNumber(
                    record(r?.matchWins ?: 0, r?.matchLosses ?: 0, r?.matchDraws ?: 0),
                    "${r?.matches ?: 0} matches · ${r?.eventsPlayed ?: 0} events · games ${record(r?.gameWins ?: 0, r?.gameLosses ?: 0, r?.gameDraws ?: 0)}" +
                        if ((r?.byes ?: 0) > 0) " · ${r?.byes} byes" else "",
                )
            }
            item { Section("Head-to-head") }
            when {
                overview == null -> item { Notice("Loading…") }
                rivals.isEmpty() -> item { Notice("Play a match to start your head-to-head.") }
                else -> items(if (showAll) rivals else rivals.take(8), key = { it.opponentId }) { rival ->
                    ListRow(rival.name, "${rival.played} match${if (rival.played == 1) "" else "es"} · games ${rival.gameWins}-${rival.gameLosses}") {
                        Text(record(rival.matchWins, rival.matchLosses, rival.matchDraws), color = T1.text, fontFamily = T1.mono, fontSize = 16.sp)
                    }
                }
            }
            if (rivals.size > 8) item {
                Row { Ghost(if (showAll) "Show fewer" else "Show all ${rivals.size}") { showAll = !showAll } }
            }

            item { Section("Settings") }
            item {
                ListRow("Display name", overview?.profile?.displayName ?: "–", onClick = { editingName = overview?.profile?.displayName ?: "" }) {
                    Label("Edit", color = T1.text)
                }
            }
            item {
                Column(
                    Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("Track games", color = T1.text, fontFamily = T1.mono, fontSize = 14.sp)
                    Label("Here in the app (life tracker) or elsewhere")
                    val modes = listOf("tracker", "elsewhere")
                    T1Segmented(listOf("Life tracker", "Elsewhere"), modes.indexOf(TrackerSettings.mode).coerceAtLeast(0)) { i ->
                        scope.launch { runCatching { TrackerSettings.set(modes[i]) }.onFailure { error = it.message } }
                    }
                }
            }
            item {
                val toggleAlerts = {
                    val next = !alertsOn
                    alertsOn = next
                    scope.launch { runCatching { Repo.setNearbyAlerts(next) }.onFailure { alertsOn = !next; error = it.message } }
                    Unit
                }
                ListRow("Nearby alerts", "Get a Join / Decline alert when an event opens near you", onClick = toggleAlerts) {
                    T1Switch(alertsOn) { toggleAlerts() }
                }
            }
            item {
                ListRow("Location and notifications", "Managed in Android settings", onClick = {
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                }) { Label("Open", color = T1.text) }
            }

            item { Section("Account") }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Sign out") { scope.launch { SignIn.signOut() } }
                    Ghost(if (deleting) "Deleting…" else "Delete account", enabled = !deleting) { confirmDelete = true }
                }
            }
        }
    }

    editingName?.let { draft ->
        T1AlertDialog(
            title = "Display name",
            onDismiss = { editingName = null },
            body = { T1TextField(draft, { editingName = it.take(40) }) },
            confirm = {
                BarAction("Save") {
                    val name = draft
                    editingName = null
                    scope.launch { runCatching { Repo.setDisplayName(name) }.onFailure { error = it.message }; load() }
                }
            },
            dismiss = { BarAction("Cancel") { editingName = null } },
        )
    }

    if (confirmDelete) {
        T1AlertDialog(
            title = "Delete your Table 1 account?",
            onDismiss = { confirmDelete = false },
            body = {
                Text(
                    "Your sign-in, name and devices are removed. Results you played stay in their events as " +
                        "\"Deleted player\". This can't be undone.",
                    fontFamily = T1.mono, color = T1.muted, fontSize = 13.sp,
                )
            },
            confirm = {
                BarAction("Delete account") {
                    confirmDelete = false
                    deleting = true
                    scope.launch {
                        runCatching { SignIn.deleteAccount() }   // session ends; AppRoot shows sign-in
                            .onFailure { error = "Couldn't delete the account: ${it.message}"; deleting = false }
                    }
                }
            },
            dismiss = { BarAction("Cancel") { confirmDelete = false } },
        )
    }
}
