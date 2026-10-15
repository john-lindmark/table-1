package site.table1.events.ui.screens

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import site.table1.events.data.NearbyEvent
import site.table1.events.data.Repo
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Screen
import site.table1.events.util.Fix
import site.table1.events.util.currentFix

/** Open events within 150 m, nearest first. Coordinates are sent once per lookup and never stored. */
@Composable
fun NearbyScreen(onJoined: (String) -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var fix by remember { mutableStateOf<Fix?>(null) }
    var events by remember { mutableStateOf<List<NearbyEvent>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var alerts by remember { mutableStateOf<Boolean?>(null) }

    fun search() {
        scope.launch {
            error = null
            val f = currentFix(context)
            if (f == null) {
                error = "Couldn't get your location. Scan the organizer's QR code instead."
                events = emptyList()
                return@launch
            }
            fix = f
            runCatching { Repo.updatePresence(f.lat, f.lng) }
            runCatching { Repo.nearbyEvents(f.lat, f.lng, f.accuracyM) }
                .onSuccess { events = it }
                .onFailure { error = it.message; events = emptyList() }
        }
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted.values.any { it }) search() else error = "Location is off. Scan the organizer's QR code to join instead."
    }
    LaunchedEffect(Unit) {
        permission.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION))
    }

    T1Screen {
        Bar("Nearby", "Events within 150 m") {
            BarAction("Refresh") { search() }
            BarAction("Back", onBack)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            Ghost(if (alerts == true) "Alerts on" else "Alert me when one starts", accent = alerts == true) {
                scope.launch {
                    val next = alerts != true
                    runCatching { Repo.setNearbyAlerts(next) }.onSuccess { alerts = next }.onFailure { error = it.message }
                }
            }
        }
        error?.let { Notice(it, error = true) }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            val list = events
            when {
                list == null -> item { Notice("Finding events near you…") }
                list.isEmpty() -> item { Notice("Nothing open nearby right now.") }
                else -> items(list, key = { it.eventId }) { e ->
                    ListRow(e.name, "${e.distanceM} m · ${e.format} · ${e.players}${e.capacity?.let { "/$it" } ?: ""} players${e.venueName?.let { " · $it" } ?: ""}") {
                        BarAction("Join") {
                            val f = fix ?: return@BarAction
                            scope.launch {
                                runCatching { Repo.joinNearby(e.eventId, f.lat, f.lng, f.accuracyM) }
                                    .onSuccess { onJoined(it.eventId) }
                                    .onFailure { error = it.message }
                            }
                        }
                    }
                }
            }
        }
    }
}
