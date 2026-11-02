package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.FullScreenDialog
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Adding a deck or cube to the collection (contract/list-to-collection-2026-10-22.md): each line goes in as the exact
   printing, finish and language the list names, either what the collection lacks of it or every copy. Cases in
   testdata/list-to-collection/cases.json, shared with iOS and the web (ListToCollectionTest). */
object ListToCollection {
    enum class Mode(val wire: String) { Missing("missing"), All("all") }

    data class Op(val cardId: String, val finish: String, val delta: Int, val lang: String = "en")

    /** Main and Commander always count, a deck's sideboard unless `sideboard` is false, Considering never. Each line
     *  goes in as the exact printing, finish and language it names, so Missing counts only owned copies of that
     *  printing, finish and language, over every condition (`owned` is keyed "card_id|finish" for English copies or
     *  "card_id|finish|lang"); another printing, finish or language of the card never covers a line here (John,
     *  2026-11-01), unlike the deck's own Missing (contract/owned-by-card-2026-10-31.md). `only` limits it to some
     *  printings (card detail). Basic lands ([basics]) are never missing, so only All adds them
     *  (contract/basics-2026-10-24.md). */
    fun ops(entries: List<ListEntry>, kind: ListKind, owned: Map<String, Int>, mode: Mode, sideboard: Boolean = true, only: Set<String>? = null,
            basics: Set<String> = emptySet()): List<Op> {
        val need = LinkedHashMap<String, Int>() // "card|finish|lang" → copies
        for (e in entries) {
            if (!(e.board == "main" || e.board == "commander" || (e.board == "side" && kind == ListKind.Deck && sideboard))) continue
            if (only != null && e.cardId !in only) continue
            if (mode == Mode.Missing && e.cardId in basics) continue
            need.merge("${ownKey(e.cardId, e.finish)}|${e.lang}", e.qty, Int::plus)
        }
        if (mode == Mode.Missing) for ((k, n) in owned) {
            val parts = k.split("|", limit = 3)
            if (parts.size < 2) continue
            val key = "${parts[0]}|${parts[1]}|${parts.getOrElse(2) { "en" }}"
            need[key]?.let { need[key] = it - n }
        }
        val out = mutableListOf<Op>()
        for ((key, n) in need) {
            if (n <= 0) continue
            val (card, finish, lang) = key.split("|", limit = 3)
            out += Op(card, finish, n, lang)
        }
        return out.sortedWith(compareBy({ it.cardId }, { it.finish }, { it.lang }))
    }

    fun copies(ops: List<Op>) = ops.sumOf { it.delta }

    /** Card detail's Add to collection row for one card in a list: a basic land is never missing, so it doesn't claim
     *  you own every copy either (contract/basics-2026-10-24.md). */
    fun cardDetail(missing: Int, basic: Boolean) =
        if (missing > 0) "Missing $missing · the printing listed here" else if (basic) "Basic land · add the copies listed here" else "You own every copy listed here"

    /** Collection ops in the picked condition, each copy in the language its line names (a non-English printing is
     *  always its own); the language picked for other adds never applies here. */
    fun collectionOps(ops: List<Op>, printingLang: (String) -> String?, condition: String): List<CollectionOp> =
        ops.map { CollectionOp(it.cardId, it.finish, condition, Languages.forNew(printingLang(it.cardId) ?: "en", it.lang), delta = it.delta) }
}

/** Add to collection from a deck or cube: what's missing or every card, sideboard or not, in one undoable batch. A list
 *  names no condition, so copies go in near mint (no picker; John, 2026-10-27). */
@Composable
fun ListToCollectionScreen(list: CardList, owned: Map<String, Int>, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val cat by CatalogStore.state.collectAsState()
    var mode by remember { mutableStateOf(ListToCollection.Mode.Missing) }
    var sideboard by remember { mutableStateOf(true) }
    var printings by remember { mutableStateOf<Map<String, CatalogPrinting>>(emptyMap()) }
    var names by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var done by remember { mutableStateOf<Pair<String, Int>?>(null) } // batch id, copies

    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    LaunchedEffect(cat.generation, list.id) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val ids = list.entries.map { it.cardId }.toSet()
        val (ps, ns) = withContext(Dispatchers.Default) {
            val ps = db.printings(ids)
            val os = db.oracles(ps.values.map { it.oracleIdx }.toSet())
            ps to ps.mapValues { (_, p) -> os[p.oracleIdx]?.name ?: "Unknown card" }
        }
        printings = ps
        names = ns
    }

    val missing = ListToCollection.ops(list.entries, list.kind, owned, ListToCollection.Mode.Missing, sideboard, basics = CatalogStore.basics)
    val all = ListToCollection.ops(list.entries, list.kind, owned, ListToCollection.Mode.All, sideboard)
    val ops = if (mode == ListToCollection.Mode.Missing) missing else all
    val copies = ListToCollection.copies(ops)
    val side = list.count("side")
    fun plural(n: Int) = "$n ${if (n == 1) "card" else "cards"}"

    Dialog(onDismissRequest = onClose, properties = FullScreenDialog) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Add to collection", list.name, onBack = onClose)
                LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    error?.let { e -> item { Notice(e, error = true) } }
                    done?.let { (batch, n) ->
                        item { Notice("Added ${plural(n)} to your collection.") }
                        item {
                            ListRow(if (busy) "Undoing…" else "Undo", "Takes those copies out again", onClick = {
                                if (busy) return@ListRow
                                busy = true
                                scope.launch {
                                    runCatching { CollectionStore.undo(batch) }.onSuccess { done = null }.onFailure { error = it.message }
                                    busy = false
                                }
                            })
                        }
                    }
                    item {
                        T1Segmented(listOf("Missing ${ListToCollection.copies(missing)}", "Every card ${ListToCollection.copies(all)}"),
                            if (mode == ListToCollection.Mode.Missing) 0 else 1) { mode = if (it == 0) ListToCollection.Mode.Missing else ListToCollection.Mode.All }
                    }
                    if (list.kind == ListKind.Deck && side > 0) item { ListRow("Sideboard", plural(side)) { T1Switch(sideboard) { sideboard = it } } }
                    item { Notice("Each card goes in near mint, as the exact printing, finish and language this ${if (list.kind == ListKind.Deck) "deck" else "cube"} lists; Missing counts only copies of those. Considering isn't added.") }
                    item { Section("To add · $copies") }
                    if (ops.isEmpty()) item {
                        ListRow(if (mode == ListToCollection.Mode.Missing) "You own every card here" else "No cards to add",
                            if (mode == ListToCollection.Mode.Missing) "Pick Every card to add another copy of each" else null)
                    }
                    items(ops, key = { "${it.cardId}|${it.finish}|${it.lang}" }) { o ->
                        val p = printings[o.cardId]
                        CardRow(p, names[o.cardId] ?: "…", listOfNotNull(p?.setLabel, if (o.finish == "nonfoil") null else Finish.of(o.finish)?.label ?: o.finish,
                            if (o.lang == "en") null else Languages.name(o.lang))
                            .joinToString(" · "), finish = o.finish) {
                            Text("+${o.delta}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                        }
                    }
                }
                Row(Modifier.fillMaxWidth().padding(bottom = 1.dp)) {
                    if (done != null) {
                        Ghost("Done") { onClose() }
                    } else {
                        Ghost(if (busy) "Adding…" else if (copies == 0) "Nothing to add" else "Add ${plural(copies)}",
                            enabled = !busy && copies > 0 && printings.isNotEmpty(), accent = true) {
                            if (ops.size > 5000) { error = "That's more than 5,000 different printings at once. Add the deck in parts."; return@Ghost }
                            busy = true
                            error = null
                            val n = copies
                            val sent = ops
                            scope.launch {
                                runCatching {
                                    CollectionStore.apply(ListToCollection.collectionOps(sent, { printings[it]?.lang }, "NM"), source = "import")
                                }.onSuccess {
                                    done = it.batchId to n
                                    Telemetry.capture("list_added_to_collection", mapOf("kind" to list.kind.wire, "mode" to mode.wire,
                                        "sideboard" to sideboard, "copies" to n, "lines" to sent.size, "from" to "list"))
                                }.onFailure { error = it.message }
                                busy = false
                            }
                        }
                    }
                }
            }
        }
    }
}
