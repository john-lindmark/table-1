package site.table1.events.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import coil3.compose.AsyncImage
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.storage.storage
import io.ktor.http.ContentType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.data.EventBundle
import site.table1.events.data.ParticipantRow
import site.table1.events.data.Repo
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import kotlin.time.Duration.Companion.hours

// Deck photos (contract/event-night-2026-10-16.md § 7; iOS DeckPhotosView): players add their own, the organizer adds
// for anyone (guests too). Each player sees their own until the event is over, the organizer sees all; then everyone
// in it does. Files live in the private `deck-photos` bucket at <event_id>/<photo_id>.jpg.

@Serializable
data class DeckPhoto(
    val id: String,
    @SerialName("participant_id") val participantId: String,
    val player: String = "",
    val path: String,
    val note: String = "",
    @SerialName("created_at") val createdAt: String? = null,
    val mine: Boolean = false,
    val editable: Boolean = false,
    /** Quarter turns clockwise to draw it upright, set after upload (0 from servers before 2026-10-30). */
    val turns: Int = 0,
)

@Serializable
data class DeckPhotos(val shared: Boolean = false, val photos: List<DeckPhoto> = emptyList())

object DeckPhotosRepo {
    private val rpc get() = T1App.supabase.postgrest
    private val bucket get() = T1App.supabase.storage.from("deck-photos")

    suspend fun list(eventId: String): DeckPhotos = rpc.rpc("deck_photos", buildJsonObject { put("p_event_id", eventId) }).decodeAs()

    /** Uploads the JPEG to <event_id>/<photo_id>.jpg, then records it for the player. */
    suspend fun add(eventId: String, participantId: String, jpeg: ByteArray, note: String): DeckPhotos {
        val id = UUID.randomUUID().toString().lowercase()
        bucket.upload("$eventId/$id.jpg", jpeg) {
            upsert = true
            contentType = ContentType.Image.JPEG
        }
        return rpc.rpc("deck_photo_add", buildJsonObject {
            put("p_id", id)
            put("p_event_id", eventId)
            put("p_participant_id", participantId)
            put("p_note", note)
        }).decodeAs()
    }

    suspend fun setNote(id: String, note: String): DeckPhotos =
        rpc.rpc("deck_photo_note", buildJsonObject { put("p_id", id); put("p_note", note) }).decodeAs()

    /** Turns an uploaded photo upright: the row keeps the quarter turns, the file never changes. */
    suspend fun turn(id: String, turns: Int): DeckPhotos =
        rpc.rpc("deck_photo_turn", buildJsonObject { put("p_id", id); put("p_turns", turns) }).decodeAs()

    suspend fun delete(photo: DeckPhoto): DeckPhotos {
        val result: DeckPhotos = rpc.rpc("deck_photo_delete", buildJsonObject { put("p_id", photo.id) }).decodeAs()
        // The file: only its uploader may remove it (storage policy); otherwise it stays, unreadable without its row.
        runCatching { bucket.delete(photo.path) }
        return result
    }

    /** A signed link for a photo (private bucket), valid an hour. */
    suspend fun url(path: String): String? = runCatching { bucket.createSignedUrl(path, 1.hours) }.getOrNull()
}

/** Longest side 2048 px, never upscaled (same as iOS and web). */
fun deckPhotoSize(width: Int, height: Int, longest: Int = 2048): Pair<Int, Int> {
    val scale = minOf(1.0, longest.toDouble() / maxOf(width, height, 1))
    return maxOf(1, Math.round(width * scale).toInt()) to maxOf(1, Math.round(height * scale).toInt())
}

/** Quarter turns clockwise, 0–3, after turning [by] more (−1 Rotate left, +1 Rotate right; iOS DeckPhotoTurns). */
fun deckPhotoTurn(turns: Int, by: Int): Int = Math.floorMod(turns + by, 4)

/** The drawn size after [turns] quarter turns: odd turns swap the sides. */
fun turnedSize(size: Pair<Int, Int>, turns: Int): Pair<Int, Int> = if (turns % 2 == 0) size else size.second to size.first

/** JPEG 80 at most 2048 px on the long side, upright (the camera's EXIF rotation applied), then turned [turns]. */
fun deckPhotoJpeg(bytes: ByteArray, turns: Int = 0): ByteArray? {
    val out = deckPhotoBitmap(bytes, turns) ?: return null
    return ByteArrayOutputStream().use { stream ->
        out.compress(Bitmap.CompressFormat.JPEG, 80, stream)
        stream.toByteArray()
    }
}

/** The photo upright and turned [turns] quarter turns clockwise, at most [longest] px on the long side. */
fun deckPhotoBitmap(bytes: ByteArray, turns: Int, longest: Int = 2048): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val longSide = maxOf(bounds.outWidth, bounds.outHeight)
    if (longSide <= 0) return null
    var sample = 1
    while (longSide / (sample * 2) >= longest) sample *= 2
    val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
        ?: return null
    val degrees = runCatching {
        when (ExifInterface(bytes.inputStream()).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> 0
        }
    }.getOrDefault(0)
    val (w, h) = deckPhotoSize(decoded.width, decoded.height, longest)
    val matrix = Matrix().apply {
        postScale(w.toFloat() / decoded.width, h.toFloat() / decoded.height)
        postRotate((degrees + 90 * turns).toFloat())
    }
    return Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
}

/** Deck photos for one event, with notes. The server decides who sees and edits what. */
@Composable
fun DeckPhotosScreen(eventId: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var bundle by remember { mutableStateOf<EventBundle?>(null) }
    var photos by remember { mutableStateOf(DeckPhotos()) }
    val urls = remember { mutableStateMapOf<String, String>() }
    var loaded by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var whose by remember { mutableStateOf(false) }
    var sourceFor by remember { mutableStateOf<ParticipantRow?>(null) }
    var picking by remember { mutableStateOf<ParticipantRow?>(null) }
    var adding by remember { mutableStateOf<Triple<ParticipantRow, Uri, String>?>(null) }
    /** The photo being added: its bytes (read once), quarter turns and a small preview drawn as it will be saved. */
    var addingBytes by remember { mutableStateOf<ByteArray?>(null) }
    var turns by remember { mutableStateOf(0) }
    var preview by remember { mutableStateOf<Bitmap?>(null) }
    var editing by remember { mutableStateOf<DeckPhoto?>(null) }
    var editMenu by remember { mutableStateOf<DeckPhoto?>(null) }
    var note by remember { mutableStateOf("") }
    /** Turns tapped but not yet saved, so Rotate answers at once. */
    val turning = remember { mutableStateMapOf<String, Int>() }

    val me = bundle?.participants?.firstOrNull { it.userId != null && it.userId == Repo.userId }
    val organizer = bundle?.isOrganizer == true

    suspend fun show(next: DeckPhotos) {
        photos = next
        for (p in next.photos) if (urls[p.path] == null) DeckPhotosRepo.url(p.path)?.let { urls[p.path] = it }
    }

    LaunchedEffect(eventId) {
        Telemetry.screen("deck_photos")
        runCatching { bundle = Repo.loadEvent(eventId) }
        runCatching { DeckPhotosRepo.list(eventId) }
            .onSuccess { show(it); error = null }
            .onFailure { error = it.message }
        loaded = true
    }

    fun upload(player: ParticipantRow, uri: Uri, source: String, text: String, turned: Int) {
        busy = true
        val read = addingBytes
        scope.launch {
            try {
                val jpeg = withContext(Dispatchers.IO) {
                    (read ?: context.contentResolver.openInputStream(uri)?.use { it.readBytes() })?.let { deckPhotoJpeg(it, turned) }
                }
                if (jpeg == null) {
                    error = "Couldn't read that photo."
                } else {
                    show(DeckPhotosRepo.add(eventId, player.id, jpeg, text))
                    error = null
                    Telemetry.capture("deck_photo_added", mapOf("source" to source, "own" to (player.id == me?.id),
                        "has_note" to text.isNotEmpty(), "turns" to turned, "event_over" to (bundle?.event?.isFinished == true)))
                }
            } catch (e: Exception) {
                error = "Couldn't save the photo: ${e.message}"
            } finally {
                busy = false
            }
        }
    }

    // The camera writes a full-size shot into cache through the app's FileProvider (not the thumbnail).
    val cameraUri = remember {
        val file = File(context.cacheDir, "deck/camera.jpg").apply { parentFile?.mkdirs() }
        FileProvider.getUriForFile(context, "${context.packageName}.avatars", file)
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val player = picking
        if (ok && player != null) { note = ""; adding = Triple(player, cameraUri, "camera") }
    }
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) camera.launch(cameraUri) else error = "Allow camera access in Android settings to take a photo."
    }
    val library = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        val player = picking
        if (uri != null && player != null) { note = ""; adding = Triple(player, uri, "library") }
    }
    val hasCamera = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }

    val event = bundle?.event
    val canAdd = event != null && !event.isCancelled && (me != null || organizer)

    T1Screen {
        Bar("Deck photos", event?.name, onBack = onBack)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (canAdd) item {
                BigAction(if (busy) "Uploading…" else "Add a deck photo", busy = busy, accent = true) {
                    if (organizer) whose = true else me?.let { sourceFor = it }
                }
            }
            error?.let { item { Notice(it, error = true) } }
            if (loaded && !photos.shared) item {
                Notice(
                    if (organizer) "Players see only their own photos until the event is over. Then everyone in it sees all of them."
                    else "Only you and the organizer see your photos until the event is over. Then everyone in it sees all of them.",
                )
            }
            when {
                !loaded -> item { Notice("Loading…") }
                photos.photos.isEmpty() -> item { Notice("No deck photos yet.") }
            }
            items(photos.photos, key = { it.id }) { photo ->
                Column(
                    Modifier.fillMaxWidth().background(T1.surface)
                        .let { if (photo.editable) it.clickable { editMenu = photo } else it },
                ) {
                    BoxWithConstraints(Modifier.fillMaxWidth().aspectRatio(4f / 3f).background(T1.bg).clipToBounds(), contentAlignment = Alignment.Center) {
                        val url = urls[photo.path]
                        val turns = turning[photo.id] ?: photo.turns
                        if (url != null) {
                            // Whole photo, never cropped, turned as its player set it: fitted into the box's swapped
                            // sides for a quarter turn, then rotated into place.
                            val odd = turns % 2 == 1
                            AsyncImage(model = url, contentDescription = "${photo.player}'s deck", contentScale = ContentScale.Fit,
                                modifier = Modifier.requiredSize(if (odd) maxHeight else maxWidth, if (odd) maxWidth else maxHeight)
                                    .rotate(turns * 90f))
                        } else {
                            Label("Loading…")
                        }
                    }
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Label(if (photo.mine) "${photo.player} · you" else photo.player, Modifier.weight(1f), color = T1.text)
                            if (photo.editable) Label("Edit")
                        }
                        if (photo.note.isNotEmpty()) Text(photo.note, color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
                    }
                }
            }
        }
    }

    // Whose deck: yourself, or (organizer) any player. Then camera or library, then a note.
    if (whose) {
        val players = bundle?.participants.orEmpty().sortedWith(compareBy({ it.id != me?.id }, { it.displayName }))
        T1Menu("Whose deck?", players.map { p ->
            T1MenuItem(if (p.id == me?.id) "${p.displayName} (you)" else p.displayName) { sourceFor = p }
        }, onDismiss = { whose = false })
    }
    sourceFor?.let { player ->
        T1Menu(player.displayName, buildList {
            if (hasCamera) add(T1MenuItem("Take a photo") {
                picking = player
                if (context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) camera.launch(cameraUri)
                else cameraPermission.launch(Manifest.permission.CAMERA)
            })
            add(T1MenuItem("Choose from photos") {
                picking = player
                library.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            })
        }, onDismiss = { sourceFor = null })
    }
    val addingUri = adding?.second
    LaunchedEffect(addingUri) {
        turns = 0
        preview = null
        addingBytes = addingUri?.let { uri -> withContext(Dispatchers.IO) { runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull() } }
    }
    LaunchedEffect(addingBytes, turns) {
        val bytes = addingBytes ?: return@LaunchedEffect
        preview = withContext(Dispatchers.Default) { deckPhotoBitmap(bytes, turns, longest = 900) }
    }
    adding?.let { (player, uri, source) ->
        T1Panel(player.displayName, onDismiss = { adding = null }, action = {
            BarAction("Save photo") {
                adding = null
                upload(player, uri, source, note.trim(), turns)
            }
        }) {
            // The whole photo, turned as it will be saved; Rotate left / right set it upright.
            Box(Modifier.fillMaxWidth().height(260.dp).background(T1.bg), contentAlignment = Alignment.Center) {
                preview?.let {
                    Image(it.asImageBitmap(), contentDescription = "Deck photo, turned ${turns * 90}°",
                        contentScale = ContentScale.Fit, modifier = Modifier.fillMaxWidth().height(260.dp))
                } ?: Label("Loading…")
            }
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                Ghost("↺ Rotate left") { turns = deckPhotoTurn(turns, -1) }
                Ghost("Rotate right ↻") { turns = deckPhotoTurn(turns, 1) }
            }
            T1TextField(note, { note = it }, label = "Note", placeholder = "Archetype, key cards, how it played…")
        }
    }
    // Rotate after upload: shown at once, saved as the photo's quarter turns.
    fun turn(photo: DeckPhoto, by: Int) {
        val next = deckPhotoTurn(turning[photo.id] ?: photo.turns, by)
        turning[photo.id] = next
        scope.launch {
            runCatching { DeckPhotosRepo.turn(photo.id, next) }
                .onSuccess { show(it); error = null; Telemetry.capture("deck_photo_turned", mapOf("turns" to next)) }
                .onFailure { error = it.message }
            if (turning[photo.id] == next) turning.remove(photo.id)
        }
    }
    editMenu?.let { photo ->
        T1Menu(photo.player, listOf(
            T1MenuItem("Rotate right ↻") { turn(photo, 1) },
            T1MenuItem("Rotate left ↺") { turn(photo, -1) },
            T1MenuItem(if (photo.note.isEmpty()) "Add a note" else "Edit note") { note = photo.note; editing = photo },
            T1MenuItem("Remove photo", danger = true) {
                scope.launch {
                    runCatching { DeckPhotosRepo.delete(photo) }
                        .onSuccess { show(it); error = null; Telemetry.capture("deck_photo_removed") }
                        .onFailure { error = it.message }
                }
            },
        ), onDismiss = { editMenu = null })
    }
    editing?.let { photo ->
        T1Panel(photo.player, onDismiss = { editing = null }, action = {
            BarAction("Save note") {
                editing = null
                val text = note.trim()
                scope.launch {
                    runCatching { DeckPhotosRepo.setNote(photo.id, text) }
                        .onSuccess { show(it); error = null; Telemetry.capture("deck_photo_note_saved", mapOf("has_note" to text.isNotEmpty())) }
                        .onFailure { error = it.message }
                }
            }
        }) {
            T1TextField(note, { note = it }, label = "Note", placeholder = "Archetype, key cards, how it played…")
        }
    }
}
