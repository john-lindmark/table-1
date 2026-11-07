package site.table1.events.ui.screens

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1TextField
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// Your deck photos on your account (contract/event-night-2026-10-16.md § 7 "On your account", 2026-11-06; iOS
// MyDeckPhotosView, web MyDeckPhotosScreen): every photo of a deck you played, across events, newest event first.

/** The Account row's summary and the screen's headings (testdata/deck-photos/cases.json `summary`, `groups`). */
object MyDeckPhotoRules {
    data class Group(val eventId: String, val title: String, val photos: List<DeckPhoto>)

    fun summary(total: Int, events: Int): String =
        if (total == 0) "None yet"
        else "$total photo${if (total == 1) "" else "s"} · $events event${if (events == 1) "" else "s"}"

    /** The server's order kept; consecutive photos of one event under one heading (its name, "Event" when blank). */
    fun groups(photos: List<DeckPhoto>): List<Group> {
        val out = mutableListOf<Group>()
        for (p in photos) {
            val last = out.lastOrNull()
            if (last != null && last.eventId == p.eventId) out[out.size - 1] = last.copy(photos = last.photos + p)
            else out += Group(p.eventId, p.eventName.trim().ifEmpty { "Event" }, listOf(p))
        }
        return out
    }

    /** "29 Oct 2026 · Draft": the event's local date, then its format unless the name already says it. */
    fun detail(p: DeckPhoto, zone: ZoneId = ZoneId.systemDefault()): String = buildList {
        runCatching { OffsetDateTime.parse(p.eventAt) }.getOrNull()?.let {
            add(it.atZoneSameInstant(zone).format(DateTimeFormatter.ofPattern("d MMM yyyy", Locale.ENGLISH)))
        }
        if (p.formatLabel.isNotEmpty() && !p.eventName.contains(p.formatLabel, ignoreCase = true)) add(p.formatLabel)
    }.joinToString(" · ")
}

/** Account → Deck photos: "12 photos · 5 events" (my_deck_photos asked for one photo, for its totals). */
fun LazyListScope.deckPhotosAccountRow(summary: String?, onOpen: () -> Unit) {
    item { ListRow("Deck photos", summary, onClick = onOpen) }
}

@Composable
fun MyDeckPhotosScreen(onBack: () -> Unit, onOpenEvent: (String) -> Unit, onOpenEventPhotos: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var mine by remember { mutableStateOf(MyDeckPhotos()) }
    val urls = remember { mutableStateMapOf<String, String>() }
    var loaded by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var menuFor by remember { mutableStateOf<DeckPhoto?>(null) }
    var editing by remember { mutableStateOf<DeckPhoto?>(null) }
    var note by remember { mutableStateOf("") }
    /** Turns tapped but not yet saved, so Rotate answers at once. */
    val turning = remember { mutableStateMapOf<String, Int>() }

    suspend fun load() {
        try {
            val next = DeckPhotosRepo.mine()
            mine = next
            for (p in next.photos) if (urls[p.path] == null) DeckPhotosRepo.url(p.path)?.let { urls[p.path] = it }
            error = null
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            error = e.message
        }
        loaded = true
    }

    fun act(event: String, props: Map<String, Any> = emptyMap(), call: suspend () -> Unit) {
        scope.launch {
            try {
                call()
                Telemetry.capture(event, props + ("from" to "account"))
                load()
            } catch (e: Exception) {
                e.rethrowIfCancelled()
                error = e.message
            }
        }
    }

    LaunchedEffect(Unit) {
        Telemetry.screen("my_deck_photos")
        load()
    }

    T1Screen {
        Bar("Deck photos", if (loaded) MyDeckPhotoRules.summary(mine.total, mine.events) else null, onBack = onBack)
        LazyColumn {
            error?.let { item { Notice(it, error = true) } }
            when {
                !loaded -> item { Notice("Loading…") }
                mine.photos.isEmpty() && error == null -> item { Notice("No deck photos yet.") }
            }
            for (group in MyDeckPhotoRules.groups(mine.photos)) {
                val detail = MyDeckPhotoRules.detail(group.photos.first())
                item(key = "h-${group.eventId}") { Section(if (detail.isEmpty()) group.title else "${group.title} · $detail") }
                items(group.photos, key = { it.id }) { photo ->
                    DeckPhotoCard(photo, urls[photo.path], turning[photo.id] ?: photo.turns, onClick = { menuFor = photo })
                }
            }
            if (loaded && mine.total > mine.photos.size) item { Notice("Showing the newest ${mine.photos.size} of ${mine.total}.") }
        }
    }

    menuFor?.let { photo ->
        val over = photo.eventStatus == "completed" || photo.eventStatus == "archived"
        T1Menu(photo.eventName.ifEmpty { photo.player }, buildList {
            add(T1MenuItem("Open event") {
                Telemetry.capture("my_deck_photo_opened", mapOf("to" to "event"))
                onOpenEvent(photo.eventId)
            })
            // Everyone in an event sees all its photos once it's over; before that, only your own.
            if (over) add(T1MenuItem("Everyone's photos from this event") {
                Telemetry.capture("my_deck_photo_opened", mapOf("to" to "event_photos"))
                onOpenEventPhotos(photo.eventId)
            })
            for ((title, by) in listOf("Rotate right ↻" to 1, "Rotate left ↺" to -1)) add(T1MenuItem(title) {
                val next = deckPhotoTurn(turning[photo.id] ?: photo.turns, by)
                turning[photo.id] = next
                scope.launch {
                    try {
                        DeckPhotosRepo.turn(photo.id, next)
                        Telemetry.capture("deck_photo_turned", mapOf("turns" to next, "from" to "account"))
                        load()
                    } catch (e: Exception) {
                        e.rethrowIfCancelled()
                        error = e.message
                    }
                    if (turning[photo.id] == next) turning.remove(photo.id)
                }
            })
            add(T1MenuItem(if (photo.note.isEmpty()) "Add a note" else "Edit note") { note = photo.note; editing = photo })
            add(T1MenuItem("Remove photo", danger = true) { act("deck_photo_removed") { DeckPhotosRepo.delete(photo) } })
        }, onDismiss = { menuFor = null })
    }
    editing?.let { photo ->
        T1Panel(photo.eventName.ifEmpty { photo.player }, onDismiss = { editing = null }, action = {
            BarAction("Save note") {
                editing = null
                val text = note.trim()
                act("deck_photo_note_saved", mapOf("has_note" to text.isNotEmpty())) { DeckPhotosRepo.setNote(photo.id, text) }
            }
        }) {
            T1TextField(note, { note = it }, label = "Note", placeholder = "Archetype, key cards, how it played…")
        }
    }
}
