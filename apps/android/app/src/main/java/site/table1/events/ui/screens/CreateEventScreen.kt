package site.table1.events.ui.screens

import android.Manifest
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import site.table1.events.data.EventNaming
import androidx.compose.ui.unit.sp
import androidx.compose.ui.Alignment
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import site.table1.events.data.DraftableSet
import site.table1.events.data.DraftPods
import site.table1.events.data.Repo
import site.table1.events.data.setEventListing
import site.table1.events.data.setEventTrios
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Stepper
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.currentFix

/** Wire value (create_event_v2 p_format_name) to label. */
internal val constructedFormats = listOf(
    "standard" to "Standard", "pioneer" to "Pioneer", "modern" to "Modern", "legacy" to "Legacy",
    "vintage" to "Vintage", "pauper" to "Pauper", "premodern" to "Premodern",
    "canadian_highlander" to "Canadian Highlander",
    // Team Trios (contract/teams-finals-alerts-2026-11-13.md § 1): teams of three, each seat its own format.
    "team_trios" to "Team Trios", "other_constructed" to "Other",
)
internal val limitedFormats = listOf("draft" to "Draft", "team_draft" to "Team draft", "sealed" to "Sealed", "team_sealed" to "Team sealed", "roto" to "Roto")

@Composable
fun CreateEventScreen(onCreated: (String) -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var limited by remember { mutableStateOf(true) }
    var format by remember { mutableStateOf("draft") }
    var formatOther by remember { mutableStateOf("") }
    var useCube by remember { mutableStateOf(false) }
    var pickedSet by remember { mutableStateOf<DraftableSet?>(null) }
    var setsUnavailable by remember { mutableStateOf(false) }
    var setNameFallback by remember { mutableStateOf("") }
    var cubeName by remember { mutableStateOf("") }
    var cubeUrl by remember { mutableStateOf("") }
    var teamSize by remember { mutableIntStateOf(4) }
    /** Team Trios: each seat's format, seat A first. */
    var seats by remember { mutableStateOf(site.table1.events.data.TeamRules.defaultSeats) }
    var rounds by remember { mutableIntStateOf(3) }
    var showClock by remember { mutableStateOf(true) }
    var includeMe by remember { mutableStateOf(true) }
    var myName by remember { mutableStateOf<String?>(null) }
    var guests by remember { mutableStateOf<List<String>>(emptyList()) }
    var nearby by remember { mutableStateOf(true) }
    // Who can find it, the description and the address (contract/public-events-leagues-2026-11-13.md § 1). Until the
    // server lists events (null = still asking), Create keeps its older Nearby + QR | QR only choice.
    var listing by remember { mutableStateOf<Boolean?>(null) }
    var find by remember { mutableStateOf("private") }
    var description by remember { mutableStateOf("") }
    var address by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var schedule by remember { mutableStateOf(ScheduleDraft()) }
    var autoRounds by remember { mutableStateOf(true) }
    var topCut by remember { mutableIntStateOf(0) }
    var decklists by remember { mutableStateOf("off") }
    /** Drafts: null = automatic pods (up to 8 each); "pod" or "cross" after round 1. */
    var podsPick by remember { mutableStateOf<Int?>(null) }
    var podPairing by remember { mutableStateOf(DraftPods.INSIDE) }
    /** Roto: null follows the players (round robin for 2–8, Swiss for 9+) until picked. */
    var pairingPicked by remember { mutableStateOf<String?>(null) }
    var formatMenu by remember { mutableStateOf(false) }
    var pickingSet by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    // If the set list is empty (not synced yet), fall back to typing the set name.
    LaunchedEffect(Unit) {
        runCatching { Repo.draftableSets("", 1) }.onSuccess { setsUnavailable = it.isEmpty() }
        myName = Repo.myDisplayName()
    }
    LaunchedEffect(Unit) { listing = ListingLive.check() }

    val options = if (limited) limitedFormats else constructedFormats
    val formatLabel = options.firstOrNull { it.first == format }?.second ?: "Event"
    val isOther = format == "other_constructed"
    val isTrios = !limited && format == "team_trios"
    val isTeam = format == "team_draft" || format == "team_sealed" || isTrios
    val cuts = site.table1.events.data.TeamRules.cutChoices(format, if (limited && format == "roto") (pairingPicked ?: "swiss") else "swiss")
    // A roto is always a cube (contract/roto-2026-10-16.md).
    val isRoto = limited && format == "roto"
    val hasPods = limited && format == "draft"
    val cube = useCube || isRoto
    val setLabel = pickedSet?.name ?: setNameFallback.trim().takeIf { setsUnavailable && it.isNotEmpty() }
    // What the server will call it: "Draft · Duskmourn · Wed 14 Oct".
    val preview = EventNaming.preview(
        if (isOther) formatOther.trim().ifEmpty { "Constructed" } else formatLabel,
        if (!limited) null else if (cube) cubeName else setLabel,
        schedule.startsAt?.toLocalDate() ?: java.time.LocalDate.now(),
    )
    val typedName = tidyName(name)
    // Swiss events of players: automatic rounds and the top cut apply.
    val playerCount = guests.size + if (includeMe) 1 else 0
    val pairing = pairingPicked ?: site.table1.events.roto.RotoMath.defaultPairing(playerCount)
    val swiss = !isTeam && !(isRoto && pairing == "round_robin")

    val cubeUrlOk = cubeUrl.isBlank() || cubeUrl.trim().startsWith("https://")
    val valid = (!isOther || formatOther.isNotBlank()) &&
        (!limited || !cube || (cubeName.isNotBlank() && cubeUrlOk))

    fun create() {
        busy = true
        error = null
        scope.launch {
            try {
                val created = Repo.createEventV2(
                    formatName = format,
                    rounds = rounds,
                    showClock = showClock,
                    setCode = if (limited && !cube) pickedSet?.code else null,
                    setName = if (limited && !cube) setLabel else null,
                    cubeName = if (limited && cube) cubeName.trim() else null,
                    cubeUrl = if (limited && cube) cubeUrl.trim().ifEmpty { null } else null,
                    teamSize = if (isTrios) 3 else if (isTeam) teamSize else null,
                    formatOther = if (isOther) formatOther.trim() else null,
                    includeMe = includeMe,
                    guests = guests,
                    name = typedName.ifEmpty { null },
                    startsAt = schedule.iso,
                    venueName = schedule.venue,
                    capacity = schedule.capacity,
                    topCut = topCut.takeIf { it in cuts && !(isRoto && pairing == "round_robin") } ?: 0,
                    autoRounds = swiss && autoRounds,
                    decklists = if (limited) "off" else decklists,
                    localDate = schedule.localDate,
                    pairing = if (isRoto) pairing else null,
                )
                // Team Trios: the seats' formats, when not the defaults (Modern / Standard / Pioneer).
                if (isTrios && seats != site.table1.events.data.TeamRules.defaultSeats) {
                    runCatching { Repo.setEventTrios(created.eventId, seats) }
                }
                // Roto: the Library cube with that name, else the Cube Cobra link imported into the Library, becomes the pool.
                if (isRoto) site.table1.events.roto.RotoApi.linkCube(created.eventId, cubeName, cubeUrl)
                // Drafts: the pods, when not the defaults (automatic, inside pods). Setup → Seating can change them.
                if (hasPods && (podsPick != null || podPairing != DraftPods.INSIDE)) {
                    runCatching { Repo.setEventPods(created.eventId, podsPick, podPairing) }
                }
                // Pin it where the organizer stands. For nearby events this also alerts opted-in players around.
                // A scheduled event is usually made away from the venue: no pin then (Details can set it there).
                val fix = if (schedule.startsAt == null) currentFix(context) else null
                val listed = listing == true && find != "private"
                if (listed) {
                    // Public or Friends: listed, with the place for distance when the organizer is at the venue.
                    runCatching {
                        Repo.setEventListing(created.eventId, find = find, description = description.trim().ifEmpty { null },
                            address = address.trim().ifEmpty { null }, place = fix?.let { it.lat to it.lng })
                    }
                } else {
                    if (fix != null) {
                        runCatching { Repo.setEventLocation(created.eventId, fix.lat, fix.lng, schedule.venue.trim().ifEmpty { null }, listing != true && nearby) }
                    }
                    if (listing == true && (description.isNotBlank() || address.isNotBlank())) {
                        runCatching { Repo.setEventListing(created.eventId, description = description.trim().ifEmpty { null }, address = address.trim().ifEmpty { null }) }
                    }
                }
                onCreated(created.eventId)
            } catch (e: Exception) {
                error = e.message
            } finally {
                busy = false
            }
        }
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { create() }

    // The set picker is its own full screen; the form keeps its state underneath.
    if (pickingSet) {
        BackHandler { pickingSet = false }
        SetPickerScreen(onPick = { pickedSet = it; pickingSet = false }, onBack = { pickingSet = false })
        return
    }

    T1Screen {
        Bar("New event", typedName.ifEmpty { preview }) { BarAction("Cancel", onCancel) }
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            FormBlock("Name") {
                T1TextField(name, { name = it.take(80) }, placeholder = preview)
            }
            FormBlock("Type") {
                T1Segmented(listOf("Constructed", "Limited"), if (limited) 1 else 0) { i ->
                    val toLimited = i == 1
                    if (toLimited != limited) {
                        limited = toLimited
                        format = if (toLimited) "draft" else "standard"
                    }
                }
            }

            FormBlock("Format") {
                T1TextField(value = formatLabel, onChange = {}, trailing = "▾", onClick = { formatMenu = true })
                if (isOther) {
                    T1TextField(formatOther, { formatOther = it.take(40) }, label = "Format name")
                }
            }

            if (limited) {
                FormBlock(if (isRoto) "Cube" else "Product") {
                    if (!isRoto) T1Segmented(listOf("Set", "Cube"), if (useCube) 1 else 0) { useCube = it == 1 }
                    if (!cube) {
                        if (setsUnavailable) {
                            T1TextField(setNameFallback, { setNameFallback = it.take(80) }, label = "Set name")
                        } else {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                pickedSet?.let { SetIcon(it.code, it.iconSvgUri, 22.dp) }
                                Box(Modifier.weight(1f)) {
                                    T1TextField(
                                        value = pickedSet?.let { "${it.name} (${it.code.uppercase()})" } ?: "",
                                        onChange = {}, label = "Set", placeholder = "Pick a set…", trailing = "›",
                                        onClick = { pickingSet = true },
                                    )
                                }
                            }
                        }
                    } else {
                        CubeFields(cubeName, { cubeName = it }, cubeUrl, { cubeUrl = it })
                    }
                }
            }

            if (isTeam && !isTrios) {
                FormBlock("Players per team") {
                    T1Segmented(listOf("3", "4"), if (teamSize == 3) 0 else 1) { teamSize = if (it == 0) 3 else 4 }
                }
            }
            if (isTrios) TrioSeatsRow(seats) { seats = it }

            if (hasPods) DraftPodsBlock(podsPick, podPairing, playerCount) { n, p -> podsPick = n; podPairing = p }

            ScheduleBlock(schedule) { schedule = it }
            if (isRoto) FormBlock("Pairing") { site.table1.events.roto.RotoPairingFields(pairing, playerCount) { pairingPicked = it } }
            if (!(isRoto && pairing == "round_robin")) CutRoundsBlock(autoRounds, { autoRounds = it }, rounds, { rounds = it }, topCut, { topCut = it }, playerCount, swiss,
                autoDetail = if (hasPods) DraftPods.autoLabel(playerCount, podsPick, podPairing) else null, cuts = cuts, teams = isTeam)
            RoundTimerRow(showClock) { showClock = it }
            if (!limited) DecklistsBlock(decklists) { decklists = it }

            PlayersBlock(includeMe, { includeMe = it }, myName, guests) { guests = it }

            if (listing == true) {
                // Public | Friends | Private: Private is the QR, code, link or invitation only.
                WhoCanFind(find) { find = it }
                DescriptionRow(description) { description = it }
                FormBlock("Address") { T1TextField(address, { address = it.take(site.table1.events.data.Leagues.ADDRESS_MAX) }, placeholder = "Street and city (optional)") }
            } else if (listing == false) {
                FormBlock("Who can find it") {
                    T1Segmented(listOf("Nearby + QR", "QR only"), if (nearby) 0 else 1) { nearby = it == 0 }
                }
                Notice(
                    if (nearby) "Players within 150 m can find and join it, and players nearby who turned on alerts get a Join / Decline notification."
                    else "Only people who scan your QR code can join.",
                )
            }
            error?.let { Notice(it, error = true) }
        }
        BigAction("Create event", accent = true, busy = busy, enabled = valid) {
            permission.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION))
        }
    }

    if (formatMenu) {
        T1Menu(
            title = "Format",
            items = options.map { (wire, label) -> T1MenuItem(label, selected = wire == format) { format = wire } },
            onDismiss = { formatMenu = false },
        )
    }
}

/** One labelled section of the form on the T1 surface. */
@Composable
internal fun FormBlock(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Label(title)
        content()
    }
}

/** Searchable list of draftable sets (newest first), as its own screen. */
@Composable
private fun SetPickerScreen(onPick: (DraftableSet) -> Unit, onBack: () -> Unit) {
    T1Screen {
        Bar("Pick a set", onBack = onBack)
        SetPickerList(onPick)
    }
}

/** Search field plus the draftable sets list (newest first). Shared by Create and the organizer's Details tab. */
@Composable
internal fun ColumnScope.SetPickerList(onPick: (DraftableSet) -> Unit) {
    var query by remember { mutableStateOf("") }
    var sets by remember { mutableStateOf<List<DraftableSet>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(query) {
        if (query.isNotEmpty()) delay(250)
        runCatching { Repo.draftableSets(query) }
            .onSuccess { sets = it; error = null }
            .onFailure { error = it.message }
    }

    Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
        T1TextField(query, { query = it.take(40) }, placeholder = "Search sets")
    }
    error?.let { Notice(it, error = true) }
    val list = sets
    when {
        list == null -> Notice("Loading…")
        list.isEmpty() -> Notice("No sets match \"$query\".")
        else -> LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            items(list, key = { it.code }) { s ->
                Row(
                    Modifier.fillMaxWidth().background(T1.surface).clickable { onPick(s) }.padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    SetIcon(s.code, s.iconSvgUri, 20.dp)
                    Column(Modifier.weight(1f)) {
                        Text(s.name, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1)
                        Label(listOfNotNull(s.code.uppercase(), s.releasedAt?.take(4)).joinToString(" · "))
                    }
                }
            }
        }
    }
}
