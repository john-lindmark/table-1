package site.table1.events.ui.screens

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.core.content.FileProvider
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Alignment
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.BuildConfig
import site.table1.events.util.Legal
import site.table1.events.auth.SignIn
import site.table1.events.data.AccountOverview
import site.table1.events.data.Repo
import site.table1.events.tracker.TrackerSettings
import site.table1.events.ui.components.Avatar
import site.table1.events.ui.components.AvatarStore
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.avatarJpeg
import site.table1.events.util.Telemetry
import java.io.File
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
import site.table1.events.library.ScanReports
import site.table1.events.library.FriendsStore
import site.table1.events.library.friendsAccountRows
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1

/** The Account tab: lifetime record, head-to-head, settings, and the account itself. */
@Composable
fun AccountScreen(foregrounds: Int, onFriends: () -> Unit, onSharing: () -> Unit, onProfile: (String) -> Unit) {
    val friends by FriendsStore.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var overview by remember { mutableStateOf<AccountOverview?>(null) }
    var alertsOn by remember { mutableStateOf(false) }
    var showAll by remember { mutableStateOf(false) }
    var editingName by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var avatarMenu by remember { mutableStateOf(false) }
    var avatarBusy by remember { mutableStateOf(false) }

    // Account photo: the camera writes into cache through a FileProvider (full size, not the thumbnail), the
    // library comes from the system photo picker; either is cropped to a 512 px JPEG before upload.
    fun saveAvatar(uri: Uri, source: String) {
        avatarBusy = true
        scope.launch {
            try {
                val jpeg = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }?.let(::avatarJpeg)
                }
                if (jpeg == null) {
                    error = "Couldn't read that photo."
                } else {
                    AvatarStore.upload(jpeg)
                    error = null
                    Telemetry.capture("avatar_photo_set", mapOf("source" to source))
                }
            } catch (e: Exception) {
                error = "Couldn't save the photo: ${e.message}"
            } finally {
                avatarBusy = false
            }
        }
    }
    val cameraUri = remember {
        val file = File(context.cacheDir, "avatar/camera.jpg").apply { parentFile?.mkdirs() }
        FileProvider.getUriForFile(context, "${context.packageName}.avatars", file)
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        if (ok) saveAvatar(cameraUri, "camera")
    }
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) camera.launch(cameraUri) else error = "Allow camera access in Android settings to take a photo."
    }
    val library = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let { saveAvatar(it, "library") }
    }
    val hasCamera = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }

    suspend fun load() {
        runCatching { Repo.accountOverview() }.onSuccess { overview = it; error = null }.onFailure { error = it.message }
        alertsOn = Repo.nearbyAlertsOn()
        TrackerSettings.refresh()
    }
    LaunchedEffect(foregrounds) {
        load()
        FriendsStore.load()
        FriendsStore.loadSharing()
    }

    val r = overview?.record
    val rivals = overview?.headToHead.orEmpty()
    T1Screen {
        Bar(overview?.label ?: "Account", "Account")
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            error?.let { item { Notice(it, error = true) } }
            item {
                // Your tile; tap to take or pick a photo, or go back to initials.
                val uid = Repo.userId
                Column(
                    Modifier.fillMaxWidth().background(T1.surface).padding(top = 24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Column(
                        Modifier.clickable(enabled = !avatarBusy && overview?.profile != null, onClickLabel = "Profile photo") {
                            avatarMenu = true
                        },
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Avatar(overview?.profile?.displayName ?: "", uid, size = 64)
                    }
                    if (avatarBusy) Label("Saving…")
                }
            }
            item {
                BigNumber(
                    record(r?.matchWins ?: 0, r?.matchLosses ?: 0, r?.matchDraws ?: 0),
                    "${r?.matches ?: 0} matches · ${r?.eventsPlayed ?: 0} events · games ${record(r?.gameWins ?: 0, r?.gameLosses ?: 0, r?.gameDraws ?: 0)}" +
                        if ((r?.byes ?: 0) > 0) " · ${r?.byes} byes" else "",
                )
            }
            Repo.userId?.let { me -> friendsAccountRows(friends, onFriends, onSharing) { onProfile(me) } }
            item { Section("Head-to-head") }
            when {
                overview == null -> item { Notice("Loading…") }
                rivals.isEmpty() -> item { Notice("Play a match to start your head-to-head.") }
                else -> items(if (showAll) rivals else rivals.take(8), key = { it.opponentId }) { rival ->
                    ListRow(rival.name, "${rival.played} match${if (rival.played == 1) "" else "es"} · games ${rival.gameWins}-${rival.gameLosses}",
                        avatar = { Avatar(rival.name, rival.opponentId) }) {
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
                var scanReports by remember { mutableStateOf(ScanReports.enabled) }
                val toggle = { scanReports = !scanReports; ScanReports.enabled = scanReports }
                ListRow("Improve scanning", "When you fix a scanned card, send the text the camera read (no photos) so we can test the scanner",
                    onClick = toggle) {
                    T1Switch(scanReports) { toggle() }
                }
            }
            item {
                var sharing by remember { mutableStateOf(Telemetry.sharing) }
                val toggle = { sharing = !sharing; Telemetry.setSharing(sharing) }
                ListRow("Share usage and crash data",
                    "Which features you use and crash reports, tied to your account id only: never names, cards or events",
                    onClick = toggle) {
                    T1Switch(sharing) { toggle() }
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

            item { Section("About") }
            item { Notice(Legal.FAN_CONTENT) }
            item {
                ListRow("Privacy policy", "table-1.site/privacy", onClick = {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(Legal.PRIVACY_URL)))
                }) { Label("Open", color = T1.text) }
            }
            item { Notice("Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})") }
        }
    }

    if (avatarMenu) {
        val uid = Repo.userId
        T1Menu(
            "Profile photo",
            listOfNotNull(
                if (hasCamera) T1MenuItem("Take a photo") {
                    if (context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) camera.launch(cameraUri)
                    else cameraPermission.launch(Manifest.permission.CAMERA)
                } else null,
                T1MenuItem("Choose from photos") {
                    library.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                },
                if (uid != null && AvatarStore.path(uid) != null) T1MenuItem("Remove photo") {
                    avatarBusy = true
                    scope.launch {
                        runCatching { AvatarStore.clear() }
                            .onSuccess { error = null; Telemetry.capture("avatar_photo_removed") }
                            .onFailure { error = it.message }
                        avatarBusy = false
                    }
                } else null,
            ),
            onDismiss = { avatarMenu = false },
        )
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
