package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Change printing (contract/change-printing-2026-10-18.md): every card line that names a printing can point some or
   all of its copies at another printing or finish, from one screen: a deck or cube line, owned copies (from the
   collection or a binder) and a trade's gets. Wants keep WantPrintingOverlay, which also offers Any printing. Same
   rules and screen as iOS ChangePrinting.swift and web ChangePrinting.tsx. */

/** Where a printing change applies. */
sealed interface PrintingTarget {
    val cardId: String
    val finish: String

    /** A deck or cube line (one list_edit swap op, so the version history shows it). */
    data class ListLine(val listId: String, override val cardId: String, val board: String, override val finish: String) : PrintingTarget

    /** Owned copies. `place`: the binder id (or [UNSORTED]) card detail was opened from; null = the collection. */
    data class Owned(val item: CollectionItem, val place: String?) : PrintingTarget {
        override val cardId get() = item.cardId
        override val finish get() = item.finish
    }

    /** A get in a trade draft: the whole line moves; `apply` gets the new card id and finish. */
    class TradeGet(val line: TradeLine, val apply: (String, String) -> Unit) : PrintingTarget {
        override val cardId get() = line.cardId
        override val finish get() = line.finish
    }

    /** `printing_changed` telemetry: where the change was made. */
    val telemetryWhere: String get() = when (this) {
        is ListLine -> "list"
        is Owned -> if (place == null) "collection" else "binder"
        is TradeGet -> "trade"
    }
}

object PrintingChange {
    /**
     * Owned copies changing printing: take `qty` out of `place` and put as many of the other printing back in the
     * same place, keeping condition, and language unless the new printing is itself non-English. One batch, so Undo
     * puts them back. Null when there's nothing to change.
     */
    fun ops(item: CollectionItem, place: String?, toCardId: String, toFinish: String, toLang: String? = null, qty: Int): List<CollectionOp>? {
        val lang = toLang?.takeIf { it != "en" } ?: item.lang
        if (qty < 1 || qty > item.qty || itemKey(toCardId, toFinish, item.condition, lang) == item.key) return null
        val binderId = place?.takeIf { it != UNSORTED }
        return listOf(
            CollectionOp(item.cardId, item.finish, item.condition, item.lang, delta = -qty, binderId = binderId),
            CollectionOp(toCardId, toFinish, item.condition, lang, delta = qty, binderId = binderId),
        )
    }

    data class Place(val place: String, val name: String, val qty: Int)

    /** Every place an item's copies sit: the binders by name, then Unsorted. */
    fun places(item: CollectionItem, binders: BindersState): List<Place> {
        val (held, unsorted) = binders.placement(item)
        return held.map { Place(it.first.id, it.first.name, it.second) } + listOfNotNull(if (unsorted > 0) Place(UNSORTED, "Unsorted", unsorted) else null)
    }

    /** The place to change from: the chosen one, else the one opened from, else the one holding the most. */
    fun pick(places: List<Place>, chosen: String?, from: String?): String? =
        chosen?.takeIf { c -> places.any { it.place == c } }
            ?: from?.takeIf { f -> places.any { it.place == f } }
            ?: places.maxByOrNull { it.qty }?.place
}

/** Points the line keyed `key` at another printing and/or finish, merging it into a line that already holds that copy. */
fun List<TradeLine>.repoint(key: String, cardId: String, finish: String): List<TradeLine> {
    val i = indexOfFirst { it.key == key }
    if (i < 0) return this
    val moved = this[i].copy(cardId = cardId, finish = finish)
    if (moved.key == key) return this
    val j = indexOfFirst { it.key == moved.key }
    return if (j >= 0) mapIndexedNotNull { n, l -> when (n) { i -> null; j -> l.copy(qty = l.qty + moved.qty); else -> l } }
    else mapIndexed { n, l -> if (n == i) moved else l }
}

/** The Change printing screen over the current one (card detail, trades), with its own screen view. */
@Composable
fun ChangePrintingOverlay(target: PrintingTarget, screen: String, onClose: () -> Unit, onChanged: (String, String) -> Unit = { _, _ -> }) {
    LaunchedEffect(Unit) { Telemetry.screen(screen) }
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) { ChangePrintingScreen(target, onClose, onChanged) }
    }
}

/**
 * The one Change printing screen: the line as it is, where from (owned copies in several places), how many, then
 * every printing of the card with a button per finish. `onChanged` gets an owned change's batch and a label, for Undo
 * on the screen underneath.
 */
@Composable
fun ChangePrintingScreen(target: PrintingTarget, onClose: () -> Unit, onChanged: (String, String) -> Unit = { _, _ -> }) {
    val col by CollectionStore.state.collectAsState()
    val bs by BindersStore.state.collectAsState()
    val ls by ListsStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val pricesVersion by PriceBook.version.collectAsState()
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    var printings by remember { mutableStateOf<List<CatalogPrinting>>(emptyList()) }
    var count by remember { mutableStateOf(0) }
    var chosen by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var pickingLang by remember { mutableStateOf(false) }
    SearchUsed(query, "change_printing")
    LaunchedEffect(cat.generation) {
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return@LaunchedEffect
        val id = target.cardId
        val found = withContext(Dispatchers.Default) {
            val p = db.printings(listOf(id))[id] ?: return@withContext null
            val o = db.oracles(listOf(p.oracleIdx))[p.oracleIdx] ?: return@withContext null
            o.name to db.printings(o.idx)
        }
        if (found != null) { name = found.first; printings = found.second }
        PriceBook.load(printings.map { it.cardId }.toSet())
    }

    // Owned copies: the item as it is now, and the places its copies sit.
    val live = (target as? PrintingTarget.Owned)?.let { col.items[it.item.key] ?: it.item }
    val places = live?.let { PrintingChange.places(it, bs) } ?: emptyList()
    val selected = (target as? PrintingTarget.Owned)?.let { PrintingChange.pick(places, chosen, it.place) }
    val list = (target as? PrintingTarget.ListLine)?.let { t -> ls.lists.firstOrNull { it.id == t.listId } }
    val have = when (target) {
        is PrintingTarget.ListLine -> list?.entries?.firstOrNull { it.cardId == target.cardId && it.board == target.board && it.finish == target.finish }?.qty ?: 0
        is PrintingTarget.Owned -> places.firstOrNull { it.place == selected }?.qty ?: 0
        is PrintingTarget.TradeGet -> target.line.qty
    }
    val n = minOf(maxOf(if (count == 0) have else count, 1), maxOf(have, 1))
    val finishLabel = { f: String -> Finish.of(f)?.label ?: f }
    val current = printings.firstOrNull { it.cardId == target.cardId }
    val shown = if (query.isEmpty()) printings else printings.filter { CardSearch.matchesPrinting(query, it.set, it.cn, it.releasedAt) }

    /** Owned copies: the same printing and finish in another language, `n` of them from the chosen place. */
    fun changeLanguage(lang: String) {
        val it = live ?: return
        val ops = LanguageChange.ops(it, places.map { pl -> pl.place to pl.qty }, lang, n, selected) ?: return
        busy = true
        error = null
        scope.launch {
            runCatching { CollectionStore.apply(ops) }
                .onSuccess { r ->
                    Telemetry.capture("language_changed", mapOf("where" to target.telemetryWhere, "copies" to n))
                    onChanged(r.batchId, "Moved $n to ${Languages.name(lang)}")
                    onClose()
                }
                .onFailure { e -> error = e.message }
            busy = false
        }
    }
    if (pickingLang && live != null) LanguagePicker(live.lang, name.ifEmpty { null }, onClose = { pickingLang = false }) { changeLanguage(it) }

    fun pick(p: CatalogPrinting, toFinish: String) {
        val props = mapOf("where" to target.telemetryWhere, "copies" to n, "finish_only" to (p.cardId == target.cardId))
        when (target) {
            is PrintingTarget.ListLine -> {
                scope.launch { runCatching { ListsStore.swap(target.listId, target.cardId, target.board, target.finish, p.cardId, toFinish, n) } }
                Telemetry.capture("printing_changed", props)
                onClose()
            }
            is PrintingTarget.TradeGet -> {
                target.apply(p.cardId, toFinish)
                Telemetry.capture("printing_changed", props)
                onClose()
            }
            is PrintingTarget.Owned -> {
                val ops = live?.let { PrintingChange.ops(it, selected, p.cardId, toFinish, p.lang, n) } ?: return
                val label = "Changed $n to ${p.setLabel}${if (toFinish == Finish.Nonfoil.wire) "" else " ${finishLabel(toFinish)}"}"
                busy = true
                error = null
                scope.launch {
                    runCatching { CollectionStore.apply(ops) }
                        .onSuccess {
                            Telemetry.capture("printing_changed", props)
                            onChanged(it.batchId, label)
                            onClose()
                        }
                        .onFailure { error = it.message }
                    busy = false
                }
            }
        }
    }

    T1Screen {
        Bar("Change printing", subtitle = name, onBack = onClose)
        error?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        if (have == 0) { Notice("This line has no copies left."); return@T1Screen }
        if (printings.size > 8) SearchBand(query, "Set, number or year") { query = it }
        Hairlines(Modifier.weight(1f)) {
            item {
                val detail = listOfNotNull(current?.setLabel, finishLabel(target.finish)) + when (target) {
                    is PrintingTarget.ListLine -> listOfNotNull(list?.boardTitle(target.board))
                    is PrintingTarget.Owned -> listOfNotNull(target.item.condition, if (target.item.lang == "en") null else target.item.lang.uppercase())
                    is PrintingTarget.TradeGet -> listOf(target.line.condition)
                }
                CardRow(current, name, detail.joinToString(" · ")) {
                    Text("$have", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            if (places.size > 1) {
                item { Section("From") }
                items(places, key = { "from-" + it.place }) { pl ->
                    ListRow(pl.name, "${pl.qty} here", onClick = { chosen = pl.place; count = pl.qty }) {
                        if (pl.place == selected) Label("From here", color = T1.accent)
                    }
                }
            }
            if (have > 1 && target !is PrintingTarget.TradeGet) item {
                Row(Modifier.fillMaxWidth().height(52.dp).background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f).padding(horizontal = 16.dp)) { Label("Change $n of $have") }
                    Stepper("−") { count = maxOf(1, n - 1) }
                    Stepper("+") { count = minOf(have, n + 1) }
                }
            }
            if (live != null) item { LanguageRow(live.lang) { pickingLang = true } }
            item { Section(if (query.isEmpty()) "Change to · ${printings.size}" else "Change to · ${shown.size} of ${printings.size}") }
            if (shown.isEmpty() && query.isNotEmpty()) item { ListRow("No printings match") }
            items(shown, key = { it.cardId }) { p ->
                val price = remember(pricesVersion, p.cardId) { PriceBook.usd(p.cardId, p.finishList.firstOrNull()?.wire ?: "nonfoil") }
                val detail = listOfNotNull(CatalogPack.RARITY_NAME[p.rarity], p.releasedAt.take(4).ifEmpty { null }, if (p.original) "Original" else null,
                    if (p.lang == "en") null else p.lang.uppercase(), PriceBook.text(price)).joinToString(" · ")
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Box(Modifier.weight(1f)) { CardRow(p, p.setLabel, detail) }
                    p.finishList.forEach { f ->
                        val same = p.cardId == target.cardId && f.wire == target.finish
                        Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable(enabled = !same && !busy) { pick(p, f.wire) }
                            .padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
                            Label(if (same) "Current" else f.label, color = if (same || busy) T1.disabled else T1.text)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Stepper(glyph: String, onClick: () -> Unit) {
    Box(Modifier.width(52.dp).fillMaxHeight().background(T1.surfaceHover).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Text(glyph, color = T1.text, fontFamily = T1.mono, fontSize = 22.sp)
    }
}
