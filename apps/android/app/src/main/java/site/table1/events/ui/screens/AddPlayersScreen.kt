package site.table1.events.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import site.table1.events.data.Repo
import site.table1.events.data.SuggestedPlayer
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.theme.T1

/**
 * Invite people to an event you're organizing. People you've shared the most events with come first;
 * search narrows that list. Email reaches existing accounts only and never says whether one exists.
 */
@Composable
fun AddPlayersScreen(eventId: String, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var people by remember { mutableStateOf<List<SuggestedPlayer>?>(null) }
    var picked by remember { mutableStateOf(setOf<String>()) }
    var email by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        runCatching { Repo.suggestedPlayers(eventId, query) }
            .onSuccess { people = it; error = null }
            .onFailure { error = it.message; if (people == null) people = emptyList() }
    }
    LaunchedEffect(query) {
        if (query.isNotEmpty()) delay(300)
        load()
    }
    val emailValid = email.trim().let { it.length > 5 && '@' in it && it.substringAfterLast('@').contains('.') }

    T1Screen {
        Bar("Add players", "Invitations — they accept to take a seat") { BarAction("Done", onDone) }
        SearchField(query, "Search people you've played with") { query = it }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            error?.let { item { Notice(it, error = true) } }
            notice?.let { item { Notice(it) } }
            item { Section(if (query.isEmpty()) "Suggested · played with you most" else "Matches") }
            val list = people
            when {
                list == null -> item { Notice("Loading…") }
                list.isEmpty() -> item {
                    Notice(if (query.isEmpty()) "No one yet. People you play with show up here; until then, invite by email below or share the QR from the event."
                           else "No one you've played with matches \"$query\".")
                }
                else -> items(list, key = { it.userId }) { p ->
                    val on = p.userId in picked
                    ListRow(p.label, "${p.sharedEvents} event${if (p.sharedEvents == 1) "" else "s"} together",
                        onClick = if (p.invited) null else ({ picked = if (on) picked - p.userId else picked + p.userId })) {
                        if (p.invited) Label("Invited")
                        else Box(Modifier.size(20.dp).background(if (on) T1.accent else T1.bg))
                    }
                }
            }
            item { Section("Invite by email") }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) { SearchField(email, "name@example.com", email = true) { email = it } }
                    Box(
                        Modifier.background(if (emailValid) T1.accent else T1.surface)
                            .clickable(enabled = emailValid && !busy) {
                                val address = email.trim()
                                busy = true
                                scope.launch {
                                    runCatching { Repo.inviteByEmail(eventId, address) }
                                        .onSuccess { email = ""; notice = "If $address has a Table 1 account, they'll get your invite." }
                                        .onFailure { error = it.message }
                                    busy = false
                                }
                            }
                            .padding(horizontal = 20.dp, vertical = 16.dp),
                    ) { Label("Send", color = if (emailValid) T1.ink else T1.muted) }
                }
            }
            item { Notice("Works for people who already have a Table 1 account. For anyone else, show them the event's QR code.") }
        }
        BigAction(if (picked.isEmpty()) "Select players" else "Invite ${picked.size}", enabled = picked.isNotEmpty(), busy = busy, accent = true) {
            busy = true
            scope.launch {
                runCatching { Repo.invitePlayers(eventId, picked.toList()) }
                    .onSuccess { n -> picked = emptySet(); notice = if (n == 1) "1 invitation sent." else "$n invitations sent."; load() }
                    .onFailure { error = it.message }
                busy = false
            }
        }
    }
}

@Composable
private fun SearchField(value: String, placeholder: String, email: Boolean = false, onChange: (String) -> Unit) {
    Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 14.dp)) {
        if (value.isEmpty()) Text(placeholder, color = T1.muted, fontFamily = T1.mono, fontSize = 15.sp)
        BasicTextField(
            value = value, onValueChange = onChange, singleLine = true,
            textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 15.sp),
            cursorBrush = SolidColor(T1.accent),
            keyboardOptions = KeyboardOptions(keyboardType = if (email) KeyboardType.Email else KeyboardType.Text),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}
