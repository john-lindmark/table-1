package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Wherever a person appears (contract/friends-sharing-2026-10-18.md § UX rules 6): profile (More), friend, request and
   sent rows, Add a friend results, trade-match rows and the trade-match screen. A long press on a row, or More, opens
   the same menu: Unfriend / Cancel request / Ignore, Block (or Unblock), Report. Same as iOS PersonActions. */

/** Who the menu is for. [relation]: friend / requested / incoming / blocked / none / self. */
data class PersonRef(val userId: String, val displayName: String, val relation: String)

/**
 * The person menu, its confirms and the Report panel. Shown while [person] isn't null; [from] is the report context
 * (profile / friends / request / search / trade_match); [changed] runs after anything that changes the relation.
 */
@Composable
fun PersonMenu(person: PersonRef?, from: String, onDismiss: () -> Unit, item: Triple<String, String, String>? = null, changed: () -> Unit = {}) {
    val scope = rememberCoroutineScope()
    var confirm by remember { mutableStateOf<String?>(null) }
    var reporting by remember { mutableStateOf<PersonRef?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    fun run(work: suspend () -> Unit) = scope.launch {
        runCatching { work() }.onSuccess { changed() }.onFailure { error = it.message }
    }
    val p = person
    if (p != null && confirm == null && reporting == null) {
        val items = buildList {
            when (p.relation) {
                "friend" -> add(T1MenuItem("Unfriend") { confirm = "unfriend" })
                "requested" -> add(T1MenuItem("Cancel request") { run { FriendsStore.remove(p.userId) }; onDismiss() })
                "incoming" -> add(T1MenuItem("Ignore request") { run { FriendsStore.respond(p.userId, false) }; onDismiss() })
            }
            if (p.relation == "blocked") add(T1MenuItem("Unblock") { run { FriendsStore.block(p.userId, false) }; onDismiss() })
            else if (p.relation != "self") add(T1MenuItem("Block", danger = true) { confirm = "block" })
            if (p.relation != "self") add(T1MenuItem("Report", danger = true) { reporting = p })
        }
        // A pick dismisses the menu; keep it open when the pick leads to a confirm or the panel.
        T1Menu(p.displayName, items) { if (confirm == null && reporting == null) onDismiss() }
    }
    val c = confirm
    if (p != null && c != null) {
        T1AlertDialog(
            title = if (c == "block") "Block ${p.displayName}?" else "Unfriend ${p.displayName}?",
            onDismiss = { confirm = null; onDismiss() },
            confirm = {
                TextButton(onClick = {
                    confirm = null
                    onDismiss()
                    run { if (c == "block") FriendsStore.block(p.userId, true) else FriendsStore.remove(p.userId) }
                }) { Label(if (c == "block") "Block" else "Unfriend", color = T1.danger) }
            },
            dismiss = { TextButton(onClick = { confirm = null; onDismiss() }) { Label("Cancel", color = T1.text) } },
            body = {
                Text(if (c == "block") BLOCK_MESSAGE else "You'll stop seeing what each of you shares with friends. They aren't told.",
                    color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp)
            },
        )
    }
    reporting?.let { r ->
        ReportPanel(r, from, item, onClose = { reporting = null; onDismiss() }, changed = changed)
    }
    error?.let { e -> T1AlertDialog("Couldn't do that", onDismiss = { error = null },
        confirm = { TextButton(onClick = { error = null }) { Label("OK", color = T1.text) } },
        body = { Text(e, color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp) }) }
}

/** Block confirms in plain words (contract § UX rules 6). */
const val BLOCK_MESSAGE = "They won't be able to find you, see your Library or ask to be friends. They won't be told. " +
    "You'll still both be in any event you're both playing."

/** Report an account: a reason, an optional note, and Also block them (on for Harassment). [item]: kind, id, name. */
@Composable
fun ReportPanel(person: PersonRef, from: String, item: Triple<String, String, String>? = null, onClose: () -> Unit, changed: () -> Unit = {}) {
    val scope = rememberCoroutineScope()
    var reason by remember { mutableStateOf<ReportReason?>(null) }
    var note by remember { mutableStateOf("") }
    var block by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var sent by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { Telemetry.screen("report") }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Report ${person.displayName}", item?.third ?: "They won't know you reported them") {
                    BarAction(if (sent) "Done" else "Cancel", onClose)
                }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    error?.let { Notice(it, error = true) }
                    if (sent) {
                        Notice("Thanks. We'll look into it. They won't know you reported them.")
                        if (block) Notice("You blocked ${person.displayName}. Unblock them any time in Friends.")
                    } else {
                        Section("What's wrong")
                        ReportReason.entries.forEach { r ->
                            ListRow(r.label, onClick = { reason = r; block = r.blocksByDefault }) {
                                if (reason == r) Label("Picked", color = T1.accent)
                            }
                        }
                        Section("Anything else · optional")
                        Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) {
                            T1TextField(note, { note = it.take(500) }, placeholder = "What happened")
                        }
                        ListRow("Also block them", "They can't find you or ask you") { T1Switch(block) { block = it } }
                    }
                }
                if (!sent) BigAction("Send report", enabled = reason != null, busy = busy, accent = true) {
                    val r = reason ?: return@BigAction
                    busy = true
                    scope.launch {
                        runCatching { FriendsStore.report(person.userId, r, note, from, item?.let { it.first to it.second }, block) }
                            .onSuccess { sent = true; error = null; changed() }
                            .onFailure { error = it.message }
                        busy = false
                    }
                }
            }
        }
    }
}

/**
 * Asks before a sharing change that reaches more people (contract § UX rules 4); a change that only narrows applies
 * at once. Call [ask] with what the change newly shows and the work to run on Show.
 */
class WideningConfirm {
    var pending by mutableStateOf<Pair<SharingRules.Widening, () -> Unit>?>(null)

    fun ask(w: SharingRules.Widening, apply: () -> Unit) {
        if (w.isEmpty) apply() else pending = w to apply
    }
}

@Composable
fun rememberWideningConfirm(): WideningConfirm {
    val c = remember { WideningConfirm() }
    c.pending?.let { (w, apply) ->
        fun done(accepted: Boolean) {
            c.pending = null
            Telemetry.capture("sharing_confirmed", mapOf("to" to if (w.anyone.isEmpty()) "friends" else "public",
                "parts" to (w.friends.size + w.anyone.size), "accepted" to accepted))
            if (accepted) apply()
        }
        T1AlertDialog(w.title, onDismiss = { done(false) },
            confirm = { TextButton(onClick = { done(true) }) { Label("Show", color = T1.accent) } },
            dismiss = { TextButton(onClick = { done(false) }) { Label("Cancel", color = T1.text) } },
            body = { Text(w.message, color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp) })
    }
    return c
}

/** The once-only "share with friends?" offers (contract § UX rules 8): the question is the confirm. */
@Composable
fun SharingOfferDialog(offer: SharingOffer, title: String, message: String, parts: List<SharePart>, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    fun answer(yes: Boolean) {
        offer.answer(yes)
        onDone()
        if (yes) scope.launch { FriendsStore.setAll(parts, Visibility.Friends) }
    }
    T1AlertDialog(title, onDismiss = { answer(false) },
        confirm = { TextButton(onClick = { answer(true) }) { Label("Share with friends", color = T1.accent) } },
        dismiss = { TextButton(onClick = { answer(false) }) { Label("Not now", color = T1.text) } },
        body = { Text(message, color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp) })
}

/**
 * "Who sees this" at the top of a deck, cube or binder (contract § UX rules 2): the effective value, and a menu to
 * change it (Same as <group>, Private, Friends, Anyone), with the profile's cap when it applies.
 */
@Composable
fun WhoSeesRow(kind: String, id: String, name: String, forTrade: Boolean? = null) {
    val st by FriendsStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    val confirm = rememberWideningConfirm()
    LaunchedEffect(Unit) { if (FriendsStore.state.value.sharing == null) FriendsStore.loadSharing() }
    val s = st.sharing ?: return
    val item = FriendsStore.shareItem(kind, id, name, forTrade)
    val group = when (kind) { "binder" -> SharePart.Binders; "cube" -> SharePart.Cubes; else -> SharePart.Decks }
    val eff = SharingRules.effective(s, item)
    val reach = SharingRules.reach(s, eff)
    val effect = if (kind == "binder") "every card in this binder, with condition and language" else "every card in this $kind"
    val detail = when {
        SharingRules.capped(s, eff) -> "Set to ${eff.label}, but only ${if (reach == Visibility.Friends) "friends see" else "you see"} it: your profile is ${s.own(SharePart.Profile)!!.label}."
        item.vis == null -> "Same as ${group.label} · ${eff.label}"
        reach == Visibility.Private -> "Only you"
        reach == Visibility.Friends -> "Friends see $effect"
        else -> "Anyone on Table 1 sees $effect"
    }
    ListRow("Who sees this", detail, onClick = { menu = true }) {
        Label(reach.label, color = if (reach == Visibility.Private) T1.muted else T1.accent)
    }
    if (menu) {
        fun pick(v: Visibility?) = confirm.ask(FriendsStore.widening(item, v)) { scope.launch { FriendsStore.set(item, v) } }
        T1Menu("Who sees this", listOf(T1MenuItem("Same as ${group.label} (${SharingRules.effective(s, group).label})", selected = item.vis == null) { pick(null) }) +
            Visibility.entries.map { v -> T1MenuItem(v.label, selected = item.vis == v) { pick(v) } }) { menu = false }
    }
}
