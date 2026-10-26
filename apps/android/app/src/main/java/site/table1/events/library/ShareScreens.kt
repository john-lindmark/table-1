package site.table1.events.library

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch
import site.table1.events.data.Repo
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Share (contract/share-links-2026-10-23.md): every part of the Library gets a Share screen with "Anyone with the link"
   (a link that works signed out, for that part only) and who sees it on Table 1. Same screens as
   apps/ios/Table1/Library/FriendsViews.swift (ShareView, SharedLinkView). */

/** The Share row on a screen; it opens the Share screen over it. [from]: all_cards / wants / binders / binder / deck / cube. */
@Composable
fun ShareRow(target: ShareTarget, from: String, onExport: (() -> Unit)? = null, onImage: (() -> Unit)? = null) {
    val state by FriendsStore.state.collectAsState()
    var open by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { if (state.sharing == null) FriendsStore.loadSharing() }
    val on = state.sharing?.links?.any(target::matches) == true
    ListRow(if (target.part == "for_trade") "Share For trade" else "Share", "Link, or who sees it on Table 1", onClick = {
        Telemetry.capture("share_opened", mapOf("part" to target.part, "from" to from))
        open = true
    }) { if (on) Label("Link on", color = T1.accent) }
    if (open) ShareScreen(target, onClose = { open = false },
        onExport = onExport?.let { f -> { open = false; f() } }, onImage = onImage?.let { f -> { open = false; f() } })
}

private fun send(context: Context, url: String) {
    val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, url)
    context.startActivity(Intent.createChooser(intent, null))
}

@Composable
fun ShareScreen(target: ShareTarget, onClose: () -> Unit, onExport: (() -> Unit)? = null, onImage: (() -> Unit)? = null) {
    val state by FriendsStore.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var ask by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var note by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { if (state.sharing == null) FriendsStore.loadSharing() }
    val s = state.sharing
    val link = s?.links?.firstOrNull(target::matches)
    fun act(work: suspend () -> Unit) {
        busy = true
        scope.launch {
            runCatching { work() }.onSuccess { error = null; note = null }.onFailure { error = it.message }
            busy = false
        }
    }
    fun copy(url: String) {
        (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText(target.title, url))
        note = "Copied"
        Telemetry.capture("share_link_sent", mapOf("part" to target.part, "how" to "copy"))
    }

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Share", target.title, onBack = onClose)
                Hairlines(Modifier.weight(1f)) {
                    item(key = "link") {
                        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            error?.let { Notice(it, error = true) }
                            Section("Anyone with the link")
                            if (link != null) {
                                Notice("Anyone with this link sees ${target.what}, even without a Table 1 account. Nothing else on your profile shows.")
                                ListRow(link.url.removePrefix("https://"), note ?: "Link on")
                                ListRow("Share link", onClick = {
                                    send(context, link.url)
                                    Telemetry.capture("share_link_sent", mapOf("part" to target.part, "how" to "share"))
                                })
                                ListRow("Copy link", onClick = { copy(link.url) })
                                ListRow("New link", onClick = { if (!busy) ask = "new" })
                                ListRow("Stop sharing link", onClick = { if (!busy) ask = "stop" }) { Label("Off", color = T1.danger) }
                            } else {
                                ListRow(if (busy) "Making a link…" else "Make a link", "Works without an account",
                                    onClick = { if (!busy && s != null) ask = "make" })
                            }
                            Section("On Table 1")
                            if (s != null) {
                                val reach = target.sharePart?.let { SharingRules.reach(s, SharingRules.effective(s, it)) } ?: run {
                                    val item = s.items.firstOrNull { it.id == target.id }
                                        ?: ShareItem(target.part, target.id ?: "", target.title, visibility = if (target.part == "deck") "private" else null)
                                    SharingRules.reach(s, SharingRules.effective(s, item))
                                }
                                ListRow("Who sees this", "Change it in Account → Sharing") {
                                    Label(if (reach == Visibility.Public) "Anyone" else reach.label, color = if (reach == Visibility.Private) T1.muted else T1.accent)
                                }
                                val me = Repo.userId
                                if (reach == Visibility.Private) Notice("Only you see it on Table 1. A link works without changing that.")
                                else if (me != null) ListRow("Send profile link", "Only ${if (reach == Visibility.Friends) "friends" else "anyone on Table 1"} can open it", onClick = {
                                    send(context, target.profileUrl(me))
                                    Telemetry.capture("share_profile_link_sent", mapOf("part" to target.part))
                                })
                            } else Notice("Loading…")
                            if (onExport != null || onImage != null) Section("As a copy")
                            onExport?.let { ListRow("Export", if (target.part == "deck") "Text, Arena, MTGO, download or copy" else "Text, Cube Cobra, download or copy", onClick = it) }
                            onImage?.let { ListRow("Deck image", "The cards as a picture, to save or share", onClick = it) }
                        }
                    }
                }
            }
        }
        ask?.let { a ->
            T1AlertDialog(
                title = when (a) { "make" -> "Make a link to ${target.title}?"; "new" -> "Make a new link?"; else -> "Stop sharing the link?" },
                onDismiss = { ask = null },
                confirm = {
                    TextButton(onClick = {
                        ask = null
                        act { if (a == "stop") FriendsStore.stopLink(target) else FriendsStore.makeLink(target, new = a == "new") }
                    }) { Label(when (a) { "make" -> "Make link"; "new" -> "New link"; else -> "Stop sharing" }, color = if (a == "stop") T1.danger else T1.text) }
                },
                dismiss = { TextButton(onClick = { ask = null }) { Label("Cancel", color = T1.text) } },
                body = {
                    Text(when (a) {
                        "make" -> target.confirmMessage
                        "new" -> "The old link stops working for anyone who has it."
                        else -> "It stops working for anyone who has it. Who sees this on Table 1 doesn't change."
                    }, color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp)
                },
            )
        }
    }
}

/** table-1.site/l/<token> in the app (signed in): what the link shows, like a profile section. */
@Composable
fun SharedLinkScreen(token: String, onBack: () -> Unit, onCard: (String) -> Unit, onList: (String) -> Unit,
                     onFollowChanges: ((String, String) -> Unit)? = null) {
    var data by remember { mutableStateOf<SharedLinkData?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(token) {
        Telemetry.screen("shared_link")
        runCatching { FriendsStore.shared(token) }
            .onSuccess {
                Telemetry.capture("shared_link_opened", mapOf("part" to it.part, "signed_in" to true, "mine" to it.mine))
                data = it
            }
            .onFailure { error = it.message }
    }
    val d = data
    if (d != null) {
        ProfileCardsScreen("", d.part, d.id, onBack, onCard, onList, link = token to d, onFollowChanges = onFollowChanges)
    } else T1Screen {
        Bar("Shared", onBack = onBack)
        error?.let {
            Notice(if ("available" in it || "42501" in it || "private" in it) "This isn't available." else it, error = true)
            Notice("The link may have been turned off.")
        } ?: Notice("Loading…")
    }
}
