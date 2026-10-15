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
import site.table1.events.data.Repo
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
    "canadian_highlander" to "Canadian Highlander", "other_constructed" to "Other",
)
internal val limitedFormats = listOf("draft" to "Draft", "team_draft" to "Team draft", "sealed" to "Sealed", "team_sealed" to "Team sealed")

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
    var rounds by remember { mutableIntStateOf(3) }
    var showClock by remember { mutableStateOf(true) }
    var includeMe by remember { mutableStateOf(true) }
    var myName by remember { mutableStateOf<String?>(null) }
    var guests by remember { mutableStateOf<List<String>>(emptyList()) }
    var venue by remember { mutableStateOf("") }
    var nearby by remember { mutableStateOf(true) }
    var formatMenu by remember { mutableStateOf(false) }
    var pickingSet by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    // If the set list is empty (not synced yet), fall back to typing the set name.
    LaunchedEffect(Unit) {
        runCatching { Repo.draftableSets("", 1) }.onSuccess { setsUnavailable = it.isEmpty() }
        myName = Repo.myDisplayName()
    }

    val options = if (limited) limitedFormats else constructedFormats
    val formatLabel = options.firstOrNull { it.first == format }?.second ?: "Event"
    val isOther = format == "other_constructed"
    val isTeam = format == "team_draft" || format == "team_sealed"
    val setLabel = pickedSet?.name ?: setNameFallback.trim().takeIf { setsUnavailable && it.isNotEmpty() }
    // What the server will call it: "Draft · Duskmourn · Wed 14 Oct".
    val preview = EventNaming.preview(
        if (isOther) formatOther.trim().ifEmpty { "Constructed" } else formatLabel,
        if (!limited) null else if (useCube) cubeName else setLabel,
    )

    val cubeUrlOk = cubeUrl.isBlank() || cubeUrl.trim().startsWith("https://")
    val valid = (!isOther || formatOther.isNotBlank()) &&
        (!limited || !useCube || (cubeName.isNotBlank() && cubeUrlOk))

    fun create() {
        busy = true
        error = null
        scope.launch {
            try {
                val created = Repo.createEventV2(
                    formatName = format,
                    rounds = rounds,
                    showClock = showClock,
                    setCode = if (limited && !useCube) pickedSet?.code else null,
                    setName = if (limited && !useCube) setLabel else null,
                    cubeName = if (limited && useCube) cubeName.trim() else null,
                    cubeUrl = if (limited && useCube) cubeUrl.trim().ifEmpty { null } else null,
                    teamSize = if (isTeam) teamSize else null,
                    formatOther = if (isOther) formatOther.trim() else null,
                    includeMe = includeMe,
                    guests = guests,
                )
                // Pin it where the organizer stands. For nearby events this also alerts opted-in players around.
                val fix = currentFix(context)
                if (fix != null) {
                    runCatching { Repo.setEventLocation(created.eventId, fix.lat, fix.lng, venue.trim().ifEmpty { null }, nearby) }
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
        Bar("New event", preview) { BarAction("Cancel", onCancel) }
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
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
                FormBlock("Product") {
                    T1Segmented(listOf("Set", "Cube"), if (useCube) 1 else 0) { useCube = it == 1 }
                    if (!useCube) {
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

            if (isTeam) {
                FormBlock("Players per team") {
                    T1Segmented(listOf("3", "4"), if (teamSize == 3) 0 else 1) { teamSize = if (it == 0) 3 else 4 }
                }
            }

            FormBlock("Rounds") {
                T1Stepper(null, rounds, 1..15, Modifier.fillMaxWidth()) { rounds = it }
            }
            RoundTimerRow(showClock) { showClock = it }

            PlayersBlock(includeMe, { includeMe = it }, myName, guests) { guests = it }

            FormBlock("Location") {
                T1TextField(venue, { venue = it.take(80) }, label = "Venue (optional)")
                Label("Who can find it")
                T1Segmented(listOf("Nearby + QR", "QR only"), if (nearby) 0 else 1) { nearby = it == 0 }
            }
            Notice(
                if (nearby) "Players within 150 m can find and join it, and players nearby who turned on alerts get a Join / Decline notification."
                else "Only people who scan your QR code can join.",
            )
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
        Bar("Pick a set") { BarAction("Back", onBack) }
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
