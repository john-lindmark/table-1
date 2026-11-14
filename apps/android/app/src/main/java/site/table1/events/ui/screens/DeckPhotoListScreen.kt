package site.table1.events.ui.screens

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import coil3.compose.AsyncImage
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.library.CardName
import site.table1.events.library.CardRow
import site.table1.events.library.CatalogOracle
import site.table1.events.library.CatalogPrinting
import site.table1.events.library.CatalogStore
import site.table1.events.library.IconGlyph
import site.table1.events.library.ListKind
import site.table1.events.library.ListsStore
import site.table1.events.library.T1Icon
import site.table1.events.library.ZoomImageScreen
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.PodHeader
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1FullScreenDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1TextAction
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled
import java.net.URL

// The decklist read from a deck photo (contract/deck-photo-lists-2026-11-13.md; iOS DeckPhotoListView): the photo, the
// list beside it, corrections by whoever may edit the photo, and Add to my decks for everyone who sees it.

object DeckPhotoListRepo {
    private val rpc get() = T1App.supabase.postgrest

    suspend fun get(photoId: String): DeckPhotoListData =
        rpc.rpc("deck_photo_list", buildJsonObject { put("p_photo_id", photoId) }).decodeAs<DeckPhotoListData>()

    /** Queues a read (the first, or again for editors); the list while one is under way. */
    suspend fun read(photoId: String): DeckPhotoListData =
        rpc.rpc("deck_photo_read_start", buildJsonObject { put("p_photo_id", photoId) }).decodeAs<DeckPhotoListData>()

    suspend fun save(photoId: String, entries: List<DeckListEntry>): DeckPhotoListData =
        rpc.rpc("deck_photo_list_save", buildJsonObject {
            put("p_photo_id", photoId)
            put("p_entries", buildJsonArray { entries.forEach { add(it.json) } })
        }).decodeAs<DeckPhotoListData>()
}

/** "Decklist · 40 cards · 2 to check" under a deck photo; a tap opens the decklist. */
@Composable
fun DeckListRow(photo: DeckPhoto, from: String, onOpen: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(T1.surface)
            .clickable(onClickLabel = "Open the decklist") {
                Telemetry.capture("deck_list_opened", mapOf("status" to (photo.list?.status ?: "none"), "mine" to photo.mine,
                    "editable" to photo.editable, "from" to from))
                onOpen(photo.id)
            }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Label(DeckPhotoList.row(photo.list), Modifier.weight(1f), color = T1.text)
        IconGlyph(T1Icon.Arrow, color = T1.muted)
    }
}

/** What the card picker is for: a line to change (its index) or a card to add. */
private data class Picking(val title: String, val query: String, val line: Int?)

@Composable
fun DeckPhotoListScreen(photoId: String, onBack: () -> Unit, onOpenDeck: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val catalog by CatalogStore.state.collectAsState()
    var data by remember { mutableStateOf<DeckPhotoListData?>(null) }
    var entries by remember { mutableStateOf(emptyList<DeckListEntry>()) }
    var url by remember { mutableStateOf<String?>(null) }
    var zoom by remember { mutableStateOf<Bitmap?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    /** Changes not yet sent (editors): saved 0.8 s after the last one. */
    var dirty by remember { mutableIntStateOf(0) }
    var saved by remember { mutableStateOf(false) }
    var outOpen by remember { mutableStateOf(false) }
    var added by remember { mutableStateOf<String?>(null) }
    var adding by remember { mutableStateOf(false) }
    var skipped by remember { mutableIntStateOf(0) }
    var menuFor by remember { mutableStateOf<Int?>(null) }
    var picking by remember { mutableStateOf<Picking?>(null) }
    var askAgain by remember { mutableStateOf(false) }
    var resumed by remember { mutableStateOf(false) }
    val printings = remember { mutableStateMapOf<String, CatalogPrinting>() }

    val d = data
    val editable = d?.editable == true
    val reading = d?.reading == true
    val counts = DeckPhotoList.counts(entries)
    val target = DeckPhotoList.target(d?.event?.eventType, d?.event?.format)
    val turns = d?.turns ?: 0

    LifecycleResumeEffect(photoId) {
        resumed = true
        onPauseOrDispose { resumed = false }
    }

    LaunchedEffect(photoId) {
        Telemetry.screen("deck_photo_list")
        CatalogStore.load(userInitiated = true)   // card art and the picker's search come from the catalog
        try {
            val got = DeckPhotoListRepo.get(photoId)
            data = got
            entries = got.entries
            error = null
            got.path?.let { url = DeckPhotosRepo.url(it) }
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            error = e.message
        }
    }

    // A phone never waits on the read: ask every 3 s while it's queued or reading and the screen is in front.
    LaunchedEffect(reading, resumed) {
        while (reading && resumed) {
            delay(3000)
            val got = runCatching { DeckPhotoListRepo.get(photoId) }.onFailure { it.rethrowIfCancelled() }.getOrNull() ?: continue
            val done = !got.reading
            data = got
            if (done) { entries = got.entries; dirty = 0 }
        }
    }

    LaunchedEffect(dirty) {
        if (dirty == 0 || !editable) return@LaunchedEffect
        val mark = dirty
        delay(800)
        try {
            val sent = entries
            val got = DeckPhotoListRepo.save(photoId, sent)
            val c = DeckPhotoList.counts(sent)
            Telemetry.capture("deck_list_saved", mapOf("lines" to sent.size, "cards" to c.main + c.side, "check" to c.check))
            if (dirty == mark) {
                dirty = 0
                data = got
                saved = true
                error = null
            }
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            error = e.message
        }
    }

    val ids = entries.mapNotNull { it.cardId }
    LaunchedEffect(ids, catalog.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val missing = ids.filter { it !in printings }
        if (missing.isEmpty()) return@LaunchedEffect
        printings.putAll(withContext(Dispatchers.IO) { db.printings(missing) })
    }

    fun change(op: String, edit: (List<DeckListEntry>) -> List<DeckListEntry>) {
        entries = edit(entries)
        added = null
        saved = false
        Telemetry.capture("deck_list_edited", mapOf("op" to op, "editable" to editable))
        if (editable) dirty += 1
    }

    fun read(again: Boolean) {
        Telemetry.capture("deck_list_read_asked", mapOf("again" to again))
        scope.launch {
            try {
                val got = DeckPhotoListRepo.read(photoId)
                dirty = 0
                data = got
                if (!again) entries = got.entries
                error = null
            } catch (e: Exception) {
                e.rethrowIfCancelled()
                error = e.message
            }
        }
    }

    fun toDeck() {
        val of = data ?: return
        val out = DeckPhotoList.deckEntries(entries)
        val mine = of.mine == true
        val c = counts
        adding = true
        scope.launch {
            try {
                val id = ListsStore.create(
                    ListKind.Deck, DeckPhotoList.deckName(of.event?.name, of.player, mine),
                    DeckPhotoList.deckFormat(of.event?.eventType, of.event?.format), out.entries,
                    if (mine) "From your deck photo" else "From ${of.player ?: "a player"}'s deck photo".take(120), "deck_photo")
                Telemetry.capture("deck_list_to_deck", mapOf("cards" to c.main + c.side, "skipped" to out.skipped, "mine" to mine,
                    "checked" to (of.checked == true)))
                skipped = out.skipped
                added = id
                error = null
            } catch (e: Exception) {
                e.rethrowIfCancelled()
                error = "Couldn't add it: ${e.message}"
            } finally {
                adding = false
            }
        }
    }

    fun openZoom() {
        val from = url ?: return
        scope.launch {
            val bytes = runCatching { withContext(Dispatchers.IO) { URL(from).readBytes() } }.getOrNull()
            val upright = bytes?.let { withContext(Dispatchers.Default) { deckPhotoBitmap(it, turns) } }
            if (upright == null) error = "Couldn't load the photo." else zoom = upright
        }
    }

    fun LazyListScope.lines(board: String) {
        entries.forEachIndexed { i, e ->
            if (e.board != board) return@forEachIndexed
            item {
                DeckListLine(e, e.cardId?.let { printings[it] }, onMenu = { menuFor = i },
                    onQty = { q -> change("qty") { DeckPhotoList.setQty(it, i, q) } })
            }
        }
    }

    T1Screen {
        Bar("Decklist", d?.let { listOfNotNull(it.player, it.event?.name).filter { s -> s.isNotEmpty() }.joinToString(" · ") }?.takeIf { it.isNotEmpty() },
            onBack = onBack) {
            if (saved) Label("Saved", color = T1.accent)
        }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            // The photo, whole and upright: it's what you correct against. A tap zooms.
            item(key = "photo") {
                BoxWithConstraints(
                    Modifier.fillMaxWidth().aspectRatio(4f / 3f).background(T1.bg).clipToBounds()
                        .clickable(enabled = url != null, onClickLabel = "Zoom") { openZoom() }
                        .semantics { contentDescription = "Deck photo. Tap to zoom." },
                    contentAlignment = Alignment.Center,
                ) {
                    val from = url
                    if (from != null) {
                        val odd = turns % 2 == 1
                        AsyncImage(model = from, contentDescription = null, contentScale = ContentScale.Fit,
                            modifier = Modifier.requiredSize(if (odd) maxHeight else maxWidth, if (odd) maxWidth else maxHeight).rotate(turns * 90f))
                    }
                }
            }
            error?.let { item(key = "error") { Notice(it, error = true) } }
            when {
                d == null -> if (error == null) item { Notice("Loading…") }
                d.reading && entries.isEmpty() -> {
                    item { Section("Reading the photo") }
                    items(d.steps.ifEmpty { listOf("Waiting to start") }) { ListRow(it) }
                }
                d.status == "none" || (d.status == "failed" && entries.isEmpty()) -> {
                    d.message?.let { item { Notice(it) } }
                    item { Row { Ghost("Read decklist", accent = true) { read(again = false) } } }
                }
                else -> {
                    item(key = "summary") {
                        Column(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(DeckPhotoList.sizeLine(counts.main, target).uppercase(), color = T1.text, fontFamily = T1.mono,
                                fontWeight = FontWeight.Bold, fontSize = 20.sp, letterSpacing = 2.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Label(deckListDetail(d, counts))
                        }
                    }
                    if (d.reading) item { Notice("Reading the photo again…") }
                    d.message?.let { item { Notice(it) } }
                    item { PodHeader("Main deck", "${counts.main}") }
                    lines("main")
                    if (counts.side > 0) {
                        item { PodHeader("Sideboard", "${counts.side}") }
                        lines("side")
                    }
                    item { Row { Ghost("Add a card") { picking = Picking("Add a card", "", null) } } }
                    if (counts.out > 0) {
                        item {
                            Box(Modifier.clickable(onClickLabel = if (outOpen) "Hide" else "Show") { outOpen = !outOpen }) {
                                PodHeader("Left out · ${counts.out}", if (outOpen) "Hide" else "Show")
                            }
                        }
                        if (outOpen) {
                            item { Notice("In the photo but not in the deck: lying sideways, off the mat or cut off.") }
                            lines("out")
                        }
                    }
                    if (editable && !d.reading && (d.readsLeft ?: 0) > 0) {
                        item { Spacer(Modifier.height(15.dp)) }
                        item { ListRow("Read the photo again", onClick = { askAgain = true }) }
                    }
                }
            }
        }
        val deck = added
        if (deck != null) {
            if (skipped > 0) Notice(DeckPhotoList.skippedLine(skipped))
            BigAction("Open deck", accent = true) { onOpenDeck(deck) }
        } else if (d != null && counts.main + counts.side > 0) {
            BigAction("Add to my decks", busy = adding) { toDeck() }
        }
    }

    menuFor?.let { i ->
        val e = entries.getOrNull(i)
        if (e != null) T1Menu(e.name, buildList {
            add(T1MenuItem("Change card") { picking = Picking(e.name, if (e.cardId == null) e.name else "", i) })
            if (e.cardId != null && !e.sure && e.board != "out") {
                add(T1MenuItem("Looks right") { change("confirm") { DeckPhotoList.confirm(it, i) } })
            }
            for ((board, title) in listOf("main" to "Move to main deck", "side" to "Move to sideboard", "out" to "Leave out of the deck")) {
                if (board != e.board) add(T1MenuItem(title) { change("move") { DeckPhotoList.move(it, i, board) } })
            }
            add(T1MenuItem("Remove", danger = true) { change("remove") { DeckPhotoList.setQty(it, i, 0) } })
        }, onDismiss = { menuFor = null })
    }
    picking?.let { p ->
        DeckListPick(p.title, p.query, onClose = { picking = null }) { card ->
            picking = null
            val line = p.line
            if (line == null) change("add") { DeckPhotoList.add(it, card, "main") }
            else change("replace") { DeckPhotoList.replace(it, line, card) }
        }
    }
    if (askAgain) {
        T1AlertDialog(
            title = "Read the photo again?",
            onDismiss = { askAgain = false },
            body = { Text("Reading again replaces this list.", fontFamily = T1.mono, color = T1.muted, fontSize = 13.sp) },
            confirm = { T1TextAction("Read again") { askAgain = false; read(again = true) } },
            dismiss = { T1TextAction("Cancel") { askAgain = false } },
        )
    }
    zoom?.let { image -> ZoomImageScreen(image, "Deck photo", d?.player, screen = "deck_photo_list") { zoom = null } }
}

/** The line under the size: sideboard, what's left to check, the pool the photo was read against. */
private fun deckListDetail(d: DeckPhotoListData, counts: DeckPhotoList.Counts): String {
    val parts = buildList {
        if (counts.side > 0) add("${counts.side} sideboard")
        if (counts.check > 0) add("${counts.check} to check") else if (d.checked == true) add("Checked")
        val label = d.pool?.label
        if (!label.isNullOrEmpty() && (d.pool?.size ?: 0) > 0) add(label)
    }
    return if (parts.isEmpty()) d.event?.formatLabel?.takeIf { it.isNotEmpty() } ?: "Read from the photo" else parts.joinToString(" · ")
}

/** One line: the card (a tap opens its menu), then − count +. A line to check says why on a second line, tagged CHECK. */
@Composable
private fun DeckListLine(e: DeckListEntry, printing: CatalogPrinting?, onMenu: () -> Unit, onQty: (Int) -> Unit) {
    val check = DeckPhotoList.toCheck(e)
    val note = when {
        e.cardId == null -> "No card by this name · tap to pick"
        check -> e.read?.takeIf { it.isNotEmpty() } ?: "Not sure"
        else -> null
    }
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        Box(Modifier.weight(1f)) {
            CardRow(printing, e.name, note, onClick = onMenu) { if (check) Label("Check", color = T1.text) }
        }
        DeckListStep("−", "One fewer", true) { onQty(e.qty - 1) }
        Box(Modifier.widthIn(min = 38.dp).fillMaxHeight().background(T1.surface), contentAlignment = Alignment.Center) {
            Text("${e.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 16.sp)
        }
        DeckListStep("+", "One more", e.qty < 99) { onQty(e.qty + 1) }
    }
}

@Composable
private fun DeckListStep(glyph: String, says: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.width(48.dp).fillMaxHeight().background(T1.surfaceHover).clickable(enabled = enabled, onClickLabel = says, onClick = onClick)
            .semantics { contentDescription = says },
        contentAlignment = Alignment.Center,
    ) {
        Text(glyph, color = if (enabled) T1.text else T1.disabled, fontFamily = T1.mono, fontSize = 20.sp)
    }
}

/** Pick the card a line really is, or a card to add: a search of every card. The pick is the card's usual printing
 *  (its original paper printing), as other adds use. */
@Composable
private fun DeckListPick(title: String, startQuery: String, onClose: () -> Unit, onPick: (DeckPhotoList.Card) -> Unit) {
    val catalog by CatalogStore.state.collectAsState()
    var query by remember { mutableStateOf(startQuery) }
    var hits by remember { mutableStateOf(emptyList<CatalogOracle>()) }
    var covers by remember { mutableStateOf(emptyMap<Int, CatalogPrinting>()) }
    LaunchedEffect(query, catalog.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val q = query
        delay(120)
        val found = withContext(Dispatchers.IO) {
            val h = db.search(q)
            h to db.covers(h.map { it.idx })
        }
        hits = found.first
        covers = found.second
    }
    T1FullScreenDialog(onDismissRequest = onClose) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar(title, onBack = onClose)
                Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
                    T1TextField(query, { query = it }, placeholder = "Card name")
                }
                LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    when {
                        CatalogStore.db == null -> item { Notice("The card catalog is still loading") }
                        CardName.norm(query).length >= 2 && hits.isEmpty() -> item { Notice("No card by that name") }
                    }
                    items(hits, key = { it.idx }) { o ->
                        CardRow(covers[o.idx], o.name, o.typeLine, onClick = {
                            covers[o.idx]?.let { onPick(DeckPhotoList.Card(it.cardId, o.name)) }
                        }) { Label("Pick", color = T1.text) }
                    }
                }
            }
        }
    }
}
