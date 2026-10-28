package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.ui.components.Avatar
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
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Friends, profiles, sharing and trade matches (contract/friends-sharing-2026-10-18.md). Same screens as the iOS app:
   Account → Friends / Sharing / Your profile; Library → Trade matches. */

private fun plural(n: Int, one: String, many: String = "${one}s") = "${count(n)} ${if (n == 1) one else many}"

/** A small action at the end of a row. */
@Composable
private fun RowAction(text: String, accent: Boolean = false, onClick: () -> Unit) {
    Box(Modifier.background(if (accent) T1.accent else T1.bg).clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 10.dp)) {
        Label(text, color = if (accent) T1.ink else T1.text)
    }
}

/* ── rows for other screens ── */

/** Account: Friends, Sharing, your profile. */
fun LazyListScope.friendsAccountRows(state: FriendsState, onFriends: () -> Unit, onSharing: () -> Unit, onProfile: () -> Unit) {
    item { Section("Friends and sharing") }
    item {
        val friends = state.list?.friends?.size ?: 0
        val waiting = state.requestsWaiting
        ListRow("Friends", listOfNotNull(plural(friends, "friend"), if (waiting > 0) "$waiting waiting" else null).joinToString(" · "),
            onClick = onFriends) { if (waiting > 0) Label("$waiting new", color = T1.accent) }
    }
    item { ListRow("Sharing", state.sharing?.let(SharingRules::summary) ?: "Who sees your profile and Library", onClick = onSharing) }
    item { ListRow("Your profile", "Name, photo and what you share", onClick = onProfile) }
}

/** One person in Trade matches (and in Trades): who, what each side has, and the value. */
@Composable
fun TradeMatchRow(x: TradeMatch, onClick: () -> Unit) {
    ListRow(x.displayName, x.short + if (x.friend) "" else " · played with you", onClick = onClick,
        avatar = { Avatar(x.displayName, x.userId) }) {
        if (x.haveUsd + x.wantUsd > 0) PriceBook.text(x.haveUsd + x.wantUsd)?.let { Text(it, color = T1.text, fontFamily = T1.mono, fontSize = 15.sp) }
    }
}

/* ── friends ── */

@Composable
fun FriendsScreen(onBack: () -> Unit, onProfile: (String) -> Unit, onAdd: () -> Unit) {
    val s by FriendsStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        Telemetry.screen("friends")
        FriendsStore.load()
    }
    fun run(id: String, work: suspend () -> Unit) {
        busy = id
        scope.launch { runCatching { work() }.onFailure { error = it.message }; busy = null }
    }
    val l = s.list
    T1Screen {
        Bar("Friends", l?.let { listOfNotNull(plural(it.friends.size, "friend"), if (it.incoming.isNotEmpty()) "${it.incoming.size} waiting" else null).joinToString(" · ") },
            onBack = onBack) { BarAction("Add", onAdd) }
        (error ?: s.error)?.let { Notice(it, error = true) }
        Hairlines(Modifier.weight(1f)) {
            item { ListRow("Add a friend", "Played with you, a name or an email", onClick = onAdd) }
            if (l == null) item { Notice("Loading…") } else {
                if (l.incoming.isNotEmpty()) item { Section("Requests · ${l.incoming.size}") }
                items(l.incoming, key = { "in" + it.userId }) { p ->
                    ListRow(p.displayName, if (busy == p.userId) "Working…" else "Asked you", onClick = { onProfile(p.userId) },
                        avatar = { Avatar(p.displayName, p.userId) }) {
                        Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            RowAction("Accept", accent = true) { run(p.userId) { FriendsStore.respond(p.userId, true) } }
                            RowAction("Decline") { run(p.userId) { FriendsStore.respond(p.userId, false) } }
                        }
                    }
                }
                item { Section("Friends · ${l.friends.size}") }
                if (l.friends.isEmpty()) item {
                    Notice("No friends yet. Friends see what you share with them, show up first in Add players, and their trades are matched against your wants.")
                }
                items(l.friends, key = { "f" + it.userId }) { p ->
                    ListRow(p.displayName, p.handle?.let { "@$it" } ?: "Friend", onClick = { onProfile(p.userId) }, avatar = { Avatar(p.displayName, p.userId) })
                }
                if (l.outgoing.isNotEmpty()) item { Section("Sent · ${l.outgoing.size}") }
                items(l.outgoing, key = { "out" + it.key }) { r ->
                    val p = r.person
                    if (p != null) {
                        ListRow(p.displayName, if (busy == r.key) "Working…" else "Requested", onClick = { onProfile(p.userId) },
                            avatar = { Avatar(p.displayName, p.userId) }) { RowAction("Cancel") { run(r.key) { FriendsStore.cancel(r) } } }
                    } else {
                        // Asked by email: only the address (the server never says whose account it is).
                        ListRow(r.label, if (busy == r.key) "Working…" else "Asked by email") { RowAction("Cancel") { run(r.key) { FriendsStore.cancel(r) } } }
                    }
                }
                if (l.blocked.isNotEmpty()) item { Section("Blocked · ${l.blocked.size}") }
                items(l.blocked, key = { "b" + it.userId }) { p ->
                    ListRow(p.displayName, "Can't see you or ask you", avatar = { Avatar(p.displayName, p.userId) }) {
                        RowAction("Unblock") { run(p.userId) { FriendsStore.block(p.userId, false) } }
                    }
                }
            }
        }
    }
}

/** Add a friend: people you've played with first; a name also finds public profiles; email never says whether an account exists. */
@Composable
fun FriendAddScreen(onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var people by remember { mutableStateOf<List<Person>?>(null) }
    var email by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    suspend fun load() {
        runCatching { FriendsStore.search(query) }.onSuccess { people = it }.onFailure { error = it.message; if (people == null) people = emptyList() }
    }
    LaunchedEffect(Unit) { Telemetry.screen("friend_add") }
    LaunchedEffect(query) {
        if (query.isNotEmpty()) delay(300)
        load()
    }
    val emailValid = email.trim().let { it.length > 5 && '@' in it && it.substringAfterLast('@').contains('.') }
    T1Screen {
        Bar("Add a friend", "They accept to become friends", onBack = onBack)
        Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
            T1TextField(query, { query = it }, placeholder = "Name or handle")
        }
        Hairlines(Modifier.weight(1f)) {
            error?.let { item { Notice(it, error = true) } }
            notice?.let { item { Notice(it) } }
            item { Section(if (query.isEmpty()) "Played with you" else "Matches") }
            val list = people
            when {
                list == null -> item { Notice("Loading…") }
                list.isEmpty() -> item {
                    Notice(if (query.isEmpty()) "People you play events with show up here. Until then, add a friend by email below."
                           else "No one you've played with or with a public profile matches \"$query\".")
                }
                else -> items(list, key = { it.userId }) { p ->
                    val detail = listOfNotNull(p.handle?.let { "@$it" },
                        if ((p.sharedEvents ?: 0) > 0) "${plural(p.sharedEvents ?: 0, "event")} together" else "Public profile").joinToString(" · ")
                    ListRow(p.displayName, detail, avatar = { Avatar(p.displayName, p.userId) }) {
                        when (p.relation ?: "none") {
                            "friend" -> Label("Friends", color = T1.accent)
                            "requested" -> Label("Requested")
                            "incoming", "none" -> RowAction(if (p.relation == "incoming") "Accept" else "Add", accent = true) {
                                if (!busy) {
                                    busy = true
                                    scope.launch {
                                        runCatching { FriendsStore.request(p.userId, if (query.isEmpty()) "played_with" else "search") }
                                            .onSuccess { st -> notice = if (st == "friends") "You and ${p.displayName} are friends." else "Asked ${p.displayName}."; load() }
                                            .onFailure { error = it.message }
                                        busy = false
                                    }
                                }
                            }
                            else -> {}
                        }
                    }
                }
            }
            item { Section("By email") }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f).background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
                        T1TextField(email, { email = it }, placeholder = "name@example.com", keyboardType = KeyboardType.Email)
                    }
                    Box(
                        Modifier.background(if (emailValid) T1.accent else T1.surface)
                            .clickable(enabled = emailValid && !busy) {
                                val address = email.trim()
                                busy = true
                                scope.launch {
                                    runCatching { FriendsStore.requestByEmail(address) }
                                        .onSuccess { email = ""; notice = "If $address has a Table 1 account, they'll get your request." }
                                        .onFailure { error = it.message }
                                    busy = false
                                }
                            }
                            .padding(horizontal = 20.dp, vertical = 16.dp),
                    ) { Label("Ask", color = if (emailValid) T1.ink else T1.muted) }
                }
            }
            item { Notice("Works for people who already have a Table 1 account.") }
        }
    }
}

/* ── profile ── */

@Composable
fun ProfileUserScreen(userId: String, onBack: () -> Unit, onSection: (kind: String, id: String?) -> Unit, onMatch: () -> Unit, onSharing: () -> Unit) {
    val scope = rememberCoroutineScope()
    var d by remember { mutableStateOf<ProfileData?>(null) }
    var match by remember { mutableStateOf<TradeMatch?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf<String?>(null) }
    var reload by remember { mutableStateOf(0) }
    LaunchedEffect(userId, reload) {
        runCatching { FriendsStore.profile(userId) }
            .onSuccess { p ->
                if (d == null) {
                    Telemetry.screen("profile")
                    Telemetry.capture("profile_viewed", mapOf("relation" to p.relation, "sections" to p.sectionCount))
                }
                d = p
                error = null
                if (p.relation != "self" && p.visible) match = runCatching { FriendsStore.matchWith(userId) }.getOrNull()
            }
            .onFailure { error = it.message }
    }
    fun run(work: suspend () -> Unit) {
        busy = true
        scope.launch { runCatching { work() }.onSuccess { reload++ }.onFailure { error = it.message }; busy = false }
    }
    val p = d
    val sub = p?.let {
        when (it.relation) {
            "self" -> "You"; "friend" -> "Friend"; "requested" -> "Requested"; "incoming" -> "Wants to be friends"; "blocked" -> "Blocked"
            else -> it.handle?.let { h -> "@$h" } ?: "Profile"
        }
    }
    T1Screen {
        Bar(p?.displayName ?: "Profile", sub, onBack = onBack) { if (p != null && p.relation != "self") BarAction("More") { menu = true } }
        error?.let { Notice(it, error = true) }
        Hairlines(Modifier.weight(1f)) {
            if (p == null) { if (error == null) item { Notice("Loading…") }; return@Hairlines }
            val s = p.sections
            item {
                Column(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Avatar(p.displayName, p.userId, size = 64)
                    Text(p.displayName, color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                    p.handle?.let { Label("@$it") }
                    s.record?.let { r ->
                        Text(listOf(r.matchWins, r.matchLosses).joinToString("-") + if (r.matchDraws > 0) "-${r.matchDraws}" else "",
                            color = T1.accent, fontFamily = T1.mono, fontSize = 36.sp, letterSpacing = 3.sp)
                        Label("${plural(r.matchWins + r.matchLosses + r.matchDraws, "match", "matches")} · ${plural(r.eventsPlayed, "event")}")
                    }
                }
            }
            when (p.relation) {
                "none" -> item { Box { BigAction("Add friend", busy = busy, accent = true) { run { FriendsStore.request(userId, "profile") } } } }
                "requested" -> item { ListRow("Requested", "They haven't answered yet") { RowAction("Cancel") { run { FriendsStore.remove(userId) } } } }
                "incoming" -> item {
                    ListRow("Wants to be friends") {
                        Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            RowAction("Accept", accent = true) { run { FriendsStore.respond(userId, true) } }
                            RowAction("Decline") { run { FriendsStore.respond(userId, false) } }
                        }
                    }
                }
                "blocked" -> item { ListRow("Blocked", "They can't see you or ask you") { RowAction("Unblock") { run { FriendsStore.block(userId, false) } } } }
                "self" -> {
                    item { Notice("You see everything here. Others see only what reaches them in Sharing.") }
                    item { ListRow("Sharing", "Choose who sees each part", onClick = onSharing) }
                }
            }
            val m = match
            if (m != null && p.relation != "self") {
                item { Section("Trade matches") }
                item {
                    ListRow(m.short, "The cards, and Start a trade", onClick = onMatch) {
                        if (m.haveUsd + m.wantUsd > 0) PriceBook.text(m.haveUsd + m.wantUsd)?.let { Text(it, color = T1.text, fontFamily = T1.mono, fontSize = 15.sp) }
                    }
                }
            }
            if (!p.visible) item { Notice(if (p.relation == "blocked") "You blocked ${p.displayName}." else "Only ${p.displayName}'s friends can see their profile.") }
            else if (p.relation != "self" && p.sectionCount == 0) item { Notice("${p.displayName} hasn't shared anything with you yet.") }
            fun open(title: String, detail: String, kind: String, id: String? = null) = item(key = "$kind-${id ?: ""}") {
                ListRow(title, detail, onClick = {
                    Telemetry.capture("profile_section_opened", mapOf("section" to kind))
                    onSection(kind, id)
                })
            }
            if (s.allCards != null || s.forTrade != null || s.wants != null) item { Section("Library") }
            s.allCards?.let { c -> open("All cards", listOfNotNull(plural(c.cards, "card"), p.valueUsd?.takeIf { it > 0 }?.let(PriceBook::text)).joinToString(" · "), "all_cards") }
            s.forTrade?.let { open("For trade", plural(it.cards, "card"), "for_trade") }
            s.wants?.let { open("Wants", "${plural(it.cards, "card")} wanted", "wants") }
            s.binders?.takeIf { it.isNotEmpty() }?.let { b ->
                item { Section("Binders · ${b.size}") }
                b.forEach { x -> open(x.name, listOfNotNull(plural(x.cards, "card"), if (x.forTrade) "For trade" else null).joinToString(" · "), "binder", x.id) }
            }
            s.decks?.takeIf { it.isNotEmpty() }?.let { l ->
                item { Section("Decks · ${l.size}") }
                l.forEach { x -> open(x.name, "${x.format} · ${plural(x.cards, "card")}", "deck", x.id) }
            }
            s.cubes?.takeIf { it.isNotEmpty() }?.let { l ->
                item { Section("Cubes · ${l.size}") }
                l.forEach { x -> open(x.name, plural(x.cards, "card"), "cube", x.id) }
            }
        }
    }
    if (menu && p != null) {
        T1Menu(p.displayName, listOfNotNull(
            if (p.relation == "friend") T1MenuItem("Unfriend") { confirm = "unfriend" } else null,
            if (p.relation == "blocked") T1MenuItem("Unblock") { run { FriendsStore.block(userId, false) } }
            else T1MenuItem("Block", danger = true) { confirm = "block" },
        )) { menu = false }
    }
    val c = confirm
    if (c != null && p != null) {
        T1AlertDialog(
            title = if (c == "block") "Block ${p.displayName}?" else "Unfriend ${p.displayName}?",
            onDismiss = { confirm = null },
            confirm = {
                TextButton(onClick = {
                    confirm = null
                    run { if (c == "block") FriendsStore.block(userId, true) else FriendsStore.remove(userId) }
                }) { Label(if (c == "block") "Block" else "Unfriend", color = T1.danger) }
            },
            dismiss = { TextButton(onClick = { confirm = null }) { Label("Cancel", color = T1.text) } },
            body = {
                Text(if (c == "block") "They won't be told. They can't ask you again or see anything of yours, even what's public."
                     else "You'll stop seeing what each of you shares with friends.", color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp)
            },
        )
    }
}

/** Binders, all cards, for trade and wants: one group per card, by name; wants for any printing show the card's default
 *  printing. (Decks and cubes go through the list lines instead.) */
internal fun groupProfileCards(rows: List<ProfileCard>, db: CatalogDb): List<CardGroup> {
    val oracles = rows.filter { it.cardId == null }.mapNotNull { it.oracleId }.toSet().mapNotNull { db.oracle(it) }
    val covers = db.covers(oracles.map { it.idx })
    val coverOf = oracles.associate { it.oracleId to covers[it.idx]?.cardId }
    val items = rows.mapNotNull { r ->
        val card = r.cardId ?: r.oracleId?.let { coverOf[it] } ?: return@mapNotNull null
        CollectionItem(card, r.finish ?: "nonfoil", r.condition ?: "NM", r.lang ?: "en", r.qty, 0)
    }
    return CardGroup.build(items, db).sortedBy { it.norm }
}

private fun boardTitle(board: String, kind: ListKind) = when (board) {
    "commander" -> "Commander"
    "main" -> if (kind == ListKind.Deck) "Main deck" else "Main"
    "side" -> "Sideboard"
    "maybe" -> "Considering"
    else -> "Cards"
}

/**
 * The cards behind one shared section, read-only, in the View you pick (list, grid or stacks, like your own); tap opens
 * the card (your own copies of it). Decks and cubes group by section, then by Group by, and add Export and Copy to my
 * Library (contract/shared-lists-grouping-2026-10-20.md).
 */
/** An Insights example list for [ProfileCardsScreen]: its cards, title, format, where it finished and Add to my decks. */
class PresetCards(val rows: List<ProfileCard>, val name: String, val format: String, val byline: String? = null,
                  val actions: (@Composable () -> Unit)? = null)

@Composable
fun ProfileCardsScreen(userId: String, section: String, item: String?, onBack: () -> Unit, onCard: (String) -> Unit, onList: (String) -> Unit,
                       onRankings: ((String) -> Unit)? = null,
                       /** A share link's token and what it shows (contract/share-links-2026-10-23.md): the cards come through it. */
                       link: Pair<String, SharedLinkData>? = null,
                       /** Someone else's binder, deck or cube: its Changes (contract/follows-2026-10-25.md). */
                       onFollowChanges: ((String, String) -> Unit)? = null,
                       /** Cards already in hand (an Insights example list): nothing to fetch, no owner, rows of its own above Export. */
                       preset: PresetCards? = null) {
    val cat by CatalogStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    val kind = SharedList.kind(section)
    var rows by remember { mutableStateOf<List<ProfileCard>?>(null) }
    var profile by remember { mutableStateOf<ProfileData?>(null) }
    /** Binders, all cards, for trade, wants: one group per card. */
    var groups by remember { mutableStateOf<List<CardGroup>>(emptyList()) }
    var keys by remember { mutableStateOf<Map<String, GroupKeys>>(emptyMap()) }
    /** Decks and cubes: one line per card, board and printing. */
    var lines by remember { mutableStateOf<List<ListLine>>(emptyList()) }
    var query by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var viewMenu by remember { mutableStateOf(false) }
    var exporting by remember { mutableStateOf(false) }
    var imaging by remember { mutableStateOf(false) }
    var copying by remember { mutableStateOf(false) }
    val printings = remember { mutableStateOf(PrintingsDisclosure()) }
    val layout = rememberCardLayout("shared.layout", "shared.grid")
    // Decks and cubes share Group by with your own; everything else has its own (None to start).
    val grouping = if (kind != null) rememberListGrouping(kind) else rememberCardGrouping(GroupingKey.SHARED, CardGrouping.None, list = false)
    // Sort the same way (all start on Name).
    val sort = if (kind != null) rememberListSort(kind) else rememberCardSort(SortPref.SHARED, CardSort.Screen.Shared)
    SearchUsed(query, "profile_cards")
    LaunchedEffect(userId, section, item) {
        if (preset == null) Telemetry.screen("profile_cards") // Insights counts its own
        CatalogStore.load(userInitiated = true)
        if (preset != null) { rows = preset.rows; return@LaunchedEffect }
        if (link != null) {
            runCatching { FriendsStore.sharedCards(link.first, section) }.onSuccess { rows = it }.onFailure { error = it.message; rows = emptyList() }
            return@LaunchedEffect
        }
        runCatching { FriendsStore.cards(userId, section, item) }.onSuccess { rows = it }.onFailure { error = it.message; rows = emptyList() }
        // The route carries ids only; the title, a list's format and its owner come from the profile.
        runCatching { FriendsStore.profile(userId) }.onSuccess { profile = it }
    }
    val entries = remember(rows) { rows?.let { SharedList.entries(it) } ?: emptyList() }
    LaunchedEffect(rows, cat.generation, grouping.value) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val r = rows ?: return@LaunchedEffect
        if (kind != null) lines = withContext(Dispatchers.Default) { resolveLines(entries, db, grouping.value) }
        else withContext(Dispatchers.Default) { groupProfileCards(r, db).let { it to GroupKeys.forGroups(it, db) } }.let { (g, k) -> groups = g; keys = k }
    }
    val s = profile?.sections
    val shared = (s?.decks.orEmpty() + s?.cubes.orEmpty()).firstOrNull { it.id == item }
    val name = preset?.name ?: link?.second?.title ?: shared?.name ?: s?.binders?.firstOrNull { it.id == item }?.name
        ?: mapOf("all_cards" to "All cards", "for_trade" to "For trade", "wants" to "Wants")[section] ?: "Cards"
    /** Whose it is; null on your own profile (no Copy there: your deck screen has Duplicate). */
    val owner = if (preset != null) null else if (link != null) link.second.owner.displayName.takeIf { !link.second.mine } else profile?.takeIf { it.relation != "self" }?.displayName
    val listFormat = preset?.format ?: if (link != null) link.second.format else shared?.format
    val searching = CardName.norm(query).isNotEmpty()
    val g = grouping.value
    fun title(key: String, qty: Int) = "${g.label(key)} · $qty"
    fun openCard(oracleId: String?) { oracleId?.let(onCard) }

    /* decks and cubes */
    fun lineTiles(inGroup: List<ListLine>): List<StackCard> = LineGroup.of(inGroup).flatMap { cg ->
        val open = { openCard(cg.lead.oracleId) }
        if (!printings.value.all || cg.lines.size < 2) listOf(StackCard(cg.id, cg.lead.printing, cg.lead.name, cg.qty, finish = cg.lead.finish, onClick = open))
        else cg.lines.map { l -> StackCard(l.key, l.printing, l.name, l.qty, finish = l.finish, onClick = open) }
    }
    val shownLines = sort.value.apply(if (searching) lines.filter { CardSearch.matches(query, it.name, it.type) } else lines) {
        SortKey.of(it.name, it.keys, it.printing)
    }
    val boards = CardList.BOARD_ORDER.filter { b -> shownLines.any { it.board == b } }
    /* binders, all cards, for trade, wants */
    val shownGroups = sort.value.apply(if (searching) groups.filter { CardSearch.matches(query, it.name, it.type) } else groups) {
        SortKey.of(it.name, keys[it.id], it.cover)
    }
    val sections = groupSections(shownGroups, g) { keys[it.id] }
    fun groupTiles(cards: List<CardGroup>) = groupTiles(cards, printings.value.all, { false }) { if (it.known) onCard(it.id) }

    // Export and Copy to my Library, above the cards.
    val top: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (link != null && !searching) ListRow(link.second.byline, avatar = { Avatar(link.second.owner.displayName, null) })
            if (preset?.byline != null && !searching) Notice(preset.byline)
            if (rows?.isEmpty() == true && error == null) Notice("Nothing here.")
            if (preset?.actions != null && !searching) preset.actions.invoke()
            val followable = section in setOf("binder", "deck", "cube") && item != null && onFollowChanges != null &&
                (if (link != null) !link.second.mine else profile != null && profile?.relation != "self")
            if (followable && !searching && item != null && onFollowChanges != null) {
                FollowRows(section, item, name, owner, link?.first) { onFollowChanges(section, item) }
            }
            if (kind != null && !rows.isNullOrEmpty() && !searching && CatalogStore.db != null) {
                ListRow("Export", if (kind == ListKind.Deck) "Text, Arena, MTGO, download or copy" else "Text, Cube Cobra, download or copy",
                    onClick = { exporting = true })
                if (kind == ListKind.Deck) ListRow("Deck image", "The cards as a picture, to save or share", onClick = { imaging = true })
                if (kind == ListKind.Cube && item != null && onRankings != null && link == null) RankingsRow(item) { onRankings(item) }
                if (owner != null && listFormat != null) {
                    ListRow(if (copying) "Copying…" else "Copy to my Library",
                        if (kind == ListKind.Deck) "A new private deck with these cards" else "A new cube with these cards",
                        onClick = {
                            if (copying) return@ListRow
                            copying = true
                            scope.launch {
                                runCatching { ListsStore.create(kind, name.take(60), listFormat, entries, SharedList.copyNote(owner, name), "profile") }
                                    .onSuccess(onList).onFailure { error = it.message }
                                copying = false
                            }
                        })
                }
            }
            if (searching && ((kind != null && shownLines.isEmpty() && lines.isNotEmpty()) || (kind == null && shownGroups.isEmpty() && groups.isNotEmpty()))) {
                ListRow("No cards match")
            }
        }
    }

    T1Screen {
        Bar(if (link != null || preset != null) name else profile?.let { "${it.displayName} · $name" } ?: "Cards", rows?.let { plural(SharedList.count(it, kind), "card") }, onBack = onBack) {
            BarAction("View") { viewMenu = true }
        }
        error?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        SearchBand(query, "Name or type") { query = it }
        if (layout.value == CardLayout.Stacks) {
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                val (cols, width) = stackColumns(maxWidth)
                LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    item(key = "top") { top() }
                    if (kind != null) for (board in boards) {
                        val inBoard = shownLines.filter { it.board == board }
                        item(key = "b-$board") { BoardHeader(boardTitle(board, kind), inBoard.sumOf { it.qty }) }
                        stackRows("s-$board", groups(inBoard, g).map { key ->
                            val inGroup = inBoard.filter { it.group == key }
                            CardStackSpec("${g.wire}|$key|${printings.value.all}", title(key, inGroup.sumOf { it.qty }), lineTiles(inGroup))
                        }, cols, width)
                    } else {
                        // Grouped: one stack per group; None: stacks of ten.
                        val stacks = if (g != CardGrouping.None) sections.map { (key, cards) ->
                            CardStackSpec("st|$key|${printings.value.all}", title(key, cards.sumOf { it.qty }), groupTiles(cards))
                        } else runStacks(groupTiles(shownGroups), false, { "" }, "st|${printings.value.all}|").map { (key, t, run) -> CardStackSpec(key, t, run) }
                        stackRows("cards", stacks, cols, width)
                    }
                }
            }
        } else if (layout.value == CardLayout.Grid) {
            CardGrid(Modifier.weight(1f)) { tile ->
                gridHeader("top") { top() }
                if (kind != null) for (board in boards) {
                    val inBoard = shownLines.filter { it.board == board }
                    gridHeader("b-$board") { BoardHeader(boardTitle(board, kind), inBoard.sumOf { it.qty }) }
                    for (key in groups(inBoard, g)) {
                        val inGroup = inBoard.filter { it.group == key }
                        gridHeader("g-$board-$key") { Section(title(key, inGroup.sumOf { it.qty })) }
                        gridItems(lineTiles(inGroup), key = { "t-$board-${it.key}" }) { t -> CardTile(t.printing, t.qty, tile, onClick = t.onClick, finish = t.finish) }
                    }
                } else for ((key, cards) in sections) {
                    if (g != CardGrouping.None) gridHeader("h-$key") { Section(title(key, cards.sumOf { it.qty })) }
                    gridItems(groupTiles(cards), key = { "t-${it.key}" }) { t -> CardTile(t.printing, t.qty, tile, onClick = t.onClick, finish = t.finish) }
                }
            }
        } else Hairlines(Modifier.weight(1f)) {
            item(key = "top") { top() }
            if (kind != null) for (board in boards) {
                val inBoard = shownLines.filter { it.board == board }
                item(key = "b-$board") { BoardHeader(boardTitle(board, kind), inBoard.sumOf { it.qty }) }
                for (key in groups(inBoard, g)) {
                    val inGroup = inBoard.filter { it.group == key }
                    item(key = "g-$board-$key") { Section(title(key, inGroup.sumOf { it.qty })) }
                    for (cg in LineGroup.of(inGroup)) {
                        val open = cg.lines.size > 1 && printings.value.open(cg.id)
                        item(key = "cg-${cg.id}") {
                            WithChevron(cg.lines.size, open, onToggle = {
                                printings.value = printings.value.toggle(cg.id)
                                Telemetry.capture("printings_toggled", mapOf("expanded" to !open, "all" to false, "screen" to "list"))
                            }) {
                                CardRow(cg.lead.printing, cg.lead.name, if (cg.lines.size > 1) "${cg.lines.size} printings · ${cg.lead.type}" else cg.lead.type,
                                    onClick = { openCard(cg.lead.oracleId) }, finish = cg.lead.finish) {
                                    Text("${cg.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                                }
                            }
                        }
                        if (open) items(cg.lines, key = { "l-${it.key}" }) { l ->
                            CardRow(l.printing, listOfNotNull(l.printing?.setLabel, l.finishLabel).joinToString(" · "), null,
                                onClick = { openCard(l.oracleId) }, finish = l.finish, indent = true) {
                                Text("${l.qty}", color = T1.muted, fontFamily = T1.mono, fontSize = 15.sp)
                            }
                        }
                    }
                }
            } else for ((key, cards) in sections) {
                if (g != CardGrouping.None) item(key = "h-$key") { Section(title(key, cards.sumOf { it.qty })) }
                for (c in cards) {
                    val open = printings.value.open(c.id)
                    cardGroupRows(c, c.type, false, open, toggle = {
                        printings.value = printings.value.toggle(c.id)
                        Telemetry.capture("printings_toggled", mapOf("expanded" to !open, "all" to false, "screen" to "list"))
                    }) { if (c.known) onCard(c.id) }
                }
            }
        }
    }
    if (viewMenu) CardLayoutMenu(layout, "profile_$section", printings, grouping, list = kind != null, sort = sort,
                                sorts = if (kind != null) CardSort.Screen.List else CardSort.Screen.Shared) { viewMenu = false }
    if (exporting && kind != null) ListExportScreen(name, kind, entries, "profile") { exporting = false }
    if (imaging && kind == ListKind.Deck) DeckImageScreen(name, listFormat ?: "", entries, owner = owner, from = "profile") { imaging = false }
}

/* ── sharing ── */

/** One part's row and its Private / Friends / Public control ("Same" first when it can follow the level above). */
@Composable
private fun SharingControl(title: String, detail: String, own: Visibility?, parent: Pair<String, Visibility>?, settings: Sharing,
                           isProfile: Boolean = false, onChange: (Visibility?) -> Unit) {
    val eff = own ?: parent?.second ?: Visibility.Private
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        ListRow(title, detail) { Label(eff.label, color = if (eff == Visibility.Private) T1.muted else T1.accent) }
        val options = (if (parent != null) listOf<Visibility?>(null) else emptyList()) + Visibility.entries
        T1Segmented(options.map { it?.label ?: "Same" }, options.indexOf(own).coerceAtLeast(0)) { onChange(options[it]) }
        if (own == null && parent != null) Notice("Same as ${parent.first}: ${parent.second.label.lowercase()}.")
        if (!isProfile && SharingRules.capped(settings, eff)) {
            Notice("Shows to ${if (SharingRules.reach(settings, eff) == Visibility.Friends) "friends" else "you"} only: your profile is " +
                "${settings.own(SharePart.Profile)!!.label.lowercase()}.")
        }
    }
}

@Composable
fun SharingScreen(onBack: () -> Unit) {
    val st by FriendsStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        Telemetry.screen("sharing")
        FriendsStore.loadSharing()
    }
    val s = st.sharing
    T1Screen {
        Bar("Sharing", s?.let(SharingRules::summary), onBack = onBack)
        st.error?.let { Notice(it, error = true) }
        Hairlines(Modifier.weight(1f)) {
            if (s == null) { item { Notice("Loading…") }; return@Hairlines }
            item { Notice("Everything starts private. Friends see what's Friends or Public; anyone on Table 1 sees what's Public. Your profile caps the rest.") }
            fun part(p: SharePart) = item(key = p.wire) {
                SharingControl(p.label, p.detail, s.own(p), if (p.inherits) "Library" to s.own(SharePart.Library)!! else null, s,
                    isProfile = p == SharePart.Profile) { v -> scope.launch { FriendsStore.set(p, v) } }
            }
            part(SharePart.Profile)
            part(SharePart.Record)
            item { Section("Library") }
            part(SharePart.Library)
            for (p in SharePart.libraryParts) {
                part(p)
                val kind = mapOf(SharePart.Binders to "binder", SharePart.Decks to "deck", SharePart.Cubes to "cube")[p] ?: continue
                val list = s.items.filter { it.kind == kind }
                if (list.isEmpty()) continue
                item(key = "each-$kind") {
                    val own = list.count { it.vis != null }
                    ListRow("Each $kind", "${plural(list.size, kind)} · " + if (own == 0) "all ${SharingRules.effective(s, p).label.lowercase()}" else "$own set on their own",
                        onClick = { open = if (open == kind) null else kind }) { Label(if (open == kind) "Close" else "Open", color = T1.text) }
                }
                if (open == kind) items(list, key = { it.id }) { i ->
                    SharingControl(i.name, if (i.forTrade == true) "For trade" else kind.replaceFirstChar { it.uppercase() }, i.vis,
                        p.label to SharingRules.effective(s, p), s) { v -> scope.launch { FriendsStore.set(i, v) } }
                }
            }
        }
    }
}

/* ── matches ── */

@Composable
fun TradeMatchesScreen(onBack: () -> Unit, onOpen: (String) -> Unit, onFriends: () -> Unit, onSharing: () -> Unit) {
    val st by FriendsStore.state.collectAsState()
    LaunchedEffect(Unit) {
        Telemetry.screen("trade_matches")
        FriendsStore.loadMatches()
        FriendsStore.state.value.matches?.let { m ->
            Telemetry.capture("trade_matches_viewed", mapOf("people" to m.size, "have" to m.sumOf { it.haveCopies }, "want" to m.sumOf { it.wantCopies }))
        }
    }
    val m = st.matches
    T1Screen {
        Bar("Trade matches", m?.let { plural(it.size, "person", "people") }, onBack = onBack)
        st.error?.let { Notice(it, error = true) }
        Hairlines(Modifier.weight(1f)) {
            item { Notice("Your wants against friends' for-trade cards, and theirs against yours. People you've played with count when they share publicly.") }
            when {
                m == null -> item { Notice("Looking…") }
                m.isEmpty() -> {
                    item { Notice("No matches yet. Matches show once friends share For trade or Wants, and you have wants or a for-trade binder.") }
                    item { ListRow("Friends", "Add friends to trade with", onClick = onFriends) }
                    item { ListRow("Sharing", "Share your For trade and Wants", onClick = onSharing) }
                }
                else -> items(m, key = { it.userId }) { x -> TradeMatchRow(x) { onOpen(x.userId) } }
            }
        }
    }
}

@Composable
fun TradeMatchScreen(userId: String, onBack: () -> Unit, onProfile: () -> Unit, onCard: (String) -> Unit, onTrade: (String) -> Unit) {
    val st by FriendsStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val pricesVersion by PriceBook.version.collectAsState()
    val scope = rememberCoroutineScope()
    var match by remember { mutableStateOf(st.matches?.firstOrNull { it.userId == userId }) }
    var loaded by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var names by remember { mutableStateOf<Map<String, Pair<CatalogPrinting?, CatalogOracle?>>>(emptyMap()) }
    LaunchedEffect(userId) {
        Telemetry.screen("trade_match")
        CatalogStore.load(userInitiated = true)
        runCatching { FriendsStore.matchWith(userId) }.onSuccess { match = it }.onFailure { error = it.message }
        loaded = true
    }
    LaunchedEffect(match, cat.generation) {
        val m = match ?: return@LaunchedEffect
        val db = CatalogStore.db ?: return@LaunchedEffect
        val ids = (m.theyHave + m.theyWant).map { it.cardId }.toSet()
        names = withContext(Dispatchers.Default) {
            val p = db.printings(ids)
            val o = db.oracles(p.values.map { it.oracleIdx }.toSet())
            ids.associateWith { id -> p[id] to p[id]?.let { o[it.oracleIdx] } }
        }
        PriceBook.load(ids)
    }
    T1Screen {
        Bar(match?.displayName ?: "Trade match", match?.let { if (it.friend) "Friend" else "Played with you" }, onBack = onBack) { BarAction("Profile", onProfile) }
        error?.let { Notice(it, error = true) }
        val m = match
        Hairlines(Modifier.weight(1f)) {
            if (m == null) { item { Notice(if (loaded) "Nothing matches with them right now." else "Looking…") }; return@Hairlines }
            fun side(title: String, lines: List<MatchLine>, value: Double, have: Boolean) {
                item(key = "h$have") { Section(title + if (value > 0) PriceBook.text(value)?.let { " · $it" } ?: "" else "") }
                if (lines.isEmpty()) item(key = "e$have") { Notice(if (have) "Nothing of theirs that you want." else "Nothing of yours that they want.") }
                items(lines, key = { "$have|${it.key}" }) { l ->
                    val (p, o) = names[l.cardId] ?: (null to null)
                    val want = when (l.want.tier) {
                        "exact" -> if (have) "You want this printing and finish" else "Wants this printing and finish"
                        "printing" -> if (have) "You want this printing" else "Wants this printing"
                        else -> if (have) "You want any printing" else "Wants any printing"
                    }
                    val detail = listOfNotNull(p?.let { "${it.set.uppercase()} ${it.cn}" }, l.finish.takeIf { it != "nonfoil" },
                        l.condition.takeIf { it != "NM" }, l.lang.takeIf { it != "en" }?.uppercase(), want).joinToString(" · ")
                    val price = remember(pricesVersion, l) { l.usd ?: PriceBook.usd(l.cardId, l.finish, l.condition) }
                    CardRow(p, o?.name ?: "…", detail, onClick = { o?.let { onCard(it.oracleId) } }) {
                        Column(horizontalAlignment = Alignment.End) {
                            Text("${l.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                            if (l.overMax == true) Label("Over your max", color = T1.danger) else PriceBook.text(price)?.let { Label(it) }
                        }
                    }
                }
            }
            side("They have · ${m.haveCopies} you want", m.theyHave, m.haveUsd, true)
            side("They want · ${m.wantCopies} you have", m.theyWant, m.wantUsd, false)
        }
        if (m != null) {
            BigAction("Start a trade", busy = busy, accent = true) {
                busy = true
                scope.launch {
                    runCatching { FriendsStore.startTrade(m) }.onSuccess(onTrade).onFailure { error = it.message }
                    busy = false
                }
            }
        }
    }
}
