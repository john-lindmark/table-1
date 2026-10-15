package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import java.util.UUID

/* Trades (contract/trades-2026-10-16.md). A trade is this account's record of a swap: what you give (copies you
   own) and what you get (any printing). Drafts save as you build them; Confirm applies both sides to the
   collection in one batch. Giving away a card a deck or cube still needs asks what to do with the list first. */

@Serializable
data class TradeLine(
    @SerialName("card_id") val cardId: String,
    val finish: String = "nonfoil",
    val condition: String = "NM",
    val lang: String = "en",
    val qty: Int = 1,
) {
    val key get() = itemKey(cardId, finish, condition, lang)
}

@Serializable
data class Trade(
    val id: String,
    val partner: String? = null,
    val note: String? = null,
    val status: String = "draft",
    val gives: List<TradeLine> = emptyList(),
    val gets: List<TradeLine> = emptyList(),
    @SerialName("batch_id") val batchId: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("confirmed_at") val confirmedAt: String? = null,
) {
    val confirmed get() = status == "confirmed"
}

@Serializable
private data class TradeConfirmResult(@SerialName("batch_id") val batchId: String? = null, val trade: Trade)

data class TradesState(val trades: List<Trade> = emptyList(), val loaded: Boolean = false, val error: String? = null)

object TradesStore {
    private val _state = MutableStateFlow(TradesState())
    val state: StateFlow<TradesState> = _state.asStateFlow()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    suspend fun load() {
        runCatching {
            T1App.supabase.postgrest.rpc("trades_list", buildJsonObject { put("p_limit", 200) }).decodeAs<List<Trade>>()
        }.onSuccess { list -> _state.update { TradesState(list, true, null) } }
            .onFailure { e -> _state.update { it.copy(error = e.message) } }
    }

    fun stop() { _state.value = TradesState() }

    fun trade(id: String) = _state.value.trades.firstOrNull { it.id == id }

    private fun put(t: Trade) = _state.update { s ->
        s.copy(trades = if (s.trades.any { it.id == t.id }) s.trades.map { if (it.id == t.id) t else it } else listOf(t) + s.trades)
    }

    /** Saves a draft (creating it when [t] is null) and returns it. */
    suspend fun save(t: Trade?, partner: String?, gives: List<TradeLine>, gets: List<TradeLine>): Trade {
        val saved = T1App.supabase.postgrest.rpc("trade_save", buildJsonObject {
            if (t == null) put("p_trade_id", JsonNull) else put("p_trade_id", t.id)
            if (partner == null) put("p_partner", JsonNull) else put("p_partner", partner)
            put("p_note", JsonNull)
            put("p_gives", json.encodeToJsonElement(gives))
            put("p_gets", json.encodeToJsonElement(gets))
        }).decodeAs<Trade>()
        put(saved)
        return saved
    }

    /** Applies the trade to the collection. */
    suspend fun confirm(t: Trade) {
        val res = T1App.supabase.postgrest.rpc("trade_confirm", buildJsonObject {
            put("p_trade_id", t.id)
            put("p_idempotency_key", UUID.randomUUID().toString())
        }).decodeAs<TradeConfirmResult>()
        put(res.trade)
        CollectionStore.sync()
    }

    suspend fun delete(t: Trade) {
        _state.update { s -> s.copy(trades = s.trades.filter { it.id != t.id }) }
        runCatching { T1App.supabase.postgrest.rpc("trade_delete", buildJsonObject { put("p_trade_id", t.id) }) }
            .onFailure { e -> _state.update { it.copy(error = e.message) } }
    }
}

/** Printing ids → finishes owned, for owned-only scanning. */
fun ownedFinishes(): Map<String, Set<String>> =
    CollectionStore.state.value.items.values.filter { it.qty > 0 }.groupBy { it.cardId }.mapValues { (_, v) -> v.map { it.finish }.toSet() }

// ── list ──────────────────────────────────────────────────────────────────

@Composable
fun TradesScreen(onBack: () -> Unit, onOpen: (String?) -> Unit) {
    val s by TradesStore.state.collectAsState()
    LaunchedEffect(Unit) { TradesStore.load() }
    val drafts = s.trades.filter { !it.confirmed }
    val done = s.trades.filter { it.confirmed }
    T1Screen {
        Bar("Trades", subtitle = if (s.loaded) "${drafts.size} open" else null, onBack = onBack)
        s.error?.let { Notice(it, error = true) }
        Hairlines(Modifier.weight(1f)) {
            item { ListRow("New trade", "What you give, what you get", onClick = { onOpen(null) }) }
            if (drafts.isNotEmpty()) item { Section("Open · ${drafts.size}") }
            items(drafts, key = { it.id }) { TradeRow(it) { onOpen(it.id) } }
            if (done.isNotEmpty()) item { Section("Confirmed · ${done.size}") }
            items(done, key = { it.id }) { TradeRow(it) { onOpen(it.id) } }
            if (s.loaded && s.trades.isEmpty()) item { Notice("No trades yet.") }
        }
    }
}

@Composable
private fun TradeRow(t: Trade, onClick: () -> Unit) {
    ListRow(t.partner ?: "Trade", "Give ${t.gives.sumOf { it.qty }} · get ${t.gets.sumOf { it.qty }} · ${(t.confirmedAt ?: t.updatedAt ?: "").take(10)}",
        onClick = onClick)
}

// ── one trade: two columns, give | get ───────────────────────────────────

private data class Conflict(val list: CardList, val oracleIdx: Int, val short: Int)

@Composable
fun TradeScreen(tradeId: String?, onBack: () -> Unit) {
    val store by TradesStore.state.collectAsState()
    val col by CollectionStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val pricesVersion by PriceBook.version.collectAsState()
    val scope = rememberCoroutineScope()
    var trade by remember { mutableStateOf<Trade?>(null) }
    var partner by remember { mutableStateOf("") }
    var gives by remember { mutableStateOf<List<TradeLine>>(emptyList()) }
    var gets by remember { mutableStateOf<List<TradeLine>>(emptyList()) }
    var started by remember { mutableStateOf(tradeId == null) }
    var meta by remember { mutableStateOf<Map<String, CatalogPrinting>>(emptyMap()) }
    var names by remember { mutableStateOf<Map<Int, String>>(emptyMap()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf<Pair<Boolean, String>?>(null) } // give?, line key
    var picking by remember { mutableStateOf<Boolean?>(null) } // give?
    var scanning by remember { mutableStateOf<Boolean?>(null) }
    var conflicts by remember { mutableStateOf<List<Conflict>?>(null) }
    var askDelete by remember { mutableStateOf(false) }
    var saveJob by remember { mutableStateOf<Job?>(null) }
    val confirmed = trade?.confirmed == true

    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    LaunchedEffect(store.loaded) {
        if (!store.loaded) TradesStore.load()
        if (!started && tradeId != null) {
            TradesStore.trade(tradeId)?.let { t -> trade = t; partner = t.partner ?: ""; gives = t.gives; gets = t.gets }
            started = true
        }
    }
    LaunchedEffect(gives.map { it.cardId } + gets.map { it.cardId }, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val ids = (gives + gets).map { it.cardId }.toSet()
        val found = withContext(Dispatchers.Default) {
            val p = db.printings(ids)
            p to db.oracles(p.values.map { it.oracleIdx }.toSet()).mapValues { it.value.name }
        }
        meta = found.first
        names = found.second
        PriceBook.load(ids)
    }
    // Drafts save half a second after the last change.
    LaunchedEffect(gives, gets, partner, started) {
        if (!started || confirmed || (trade == null && gives.isEmpty() && gets.isEmpty())) return@LaunchedEffect
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(500)
            runCatching { TradesStore.save(trade, partner.trim().ifEmpty { null }, gives, gets) }
                .onSuccess { trade = it }.onFailure { error = it.message }
        }
    }

    /** Market value of a side; null when none of its cards has a market price. */
    fun sum(lines: List<TradeLine>): Double? =
        lines.mapNotNull { l -> PriceBook.usd(l.cardId, l.finish)?.let { it * l.qty } }.takeIf { it.isNotEmpty() }?.sum()

    fun add(give: Boolean, line: TradeLine) {
        if (give) {
            val have = col.items[line.key]?.qty ?: 0
            gives = if (gives.any { it.key == line.key }) gives.map { if (it.key == line.key) it.copy(qty = minOf(it.qty + line.qty, maxOf(have, it.qty))) else it }
            else gives + line
        } else {
            gets = if (gets.any { it.key == line.key }) gets.map { if (it.key == line.key) it.copy(qty = it.qty + line.qty) else it } else gets + line
        }
    }

    fun update(give: Boolean, key: String, next: TradeLine?) {
        val f: (List<TradeLine>) -> List<TradeLine> = { l -> if (next == null) l.filter { it.key != key } else l.map { if (it.key == key) next else it } }
        if (give) gives = f(gives) else gets = f(gets)
    }

    /** Lists that would need more copies than you'll have left after giving these away. */
    fun findConflicts(): List<Conflict> {
        val db = CatalogStore.db ?: return emptyList()
        val giving = gives.mapNotNull { meta[it.cardId]?.oracleIdx }.toSet()
        if (giving.isEmpty()) return emptyList()
        val lists = ListsStore.state.value.lists
        val printing = db.printings(col.items.values.map { it.cardId }.toSet() + lists.flatMap { l -> l.entries.map { it.cardId } })
        val have = HashMap<Int, Int>()
        for (it in col.items.values) printing[it.cardId]?.oracleIdx?.takeIf { o -> o in giving }?.let { o -> have[o] = (have[o] ?: 0) + it.qty }
        for (l in gives) meta[l.cardId]?.oracleIdx?.let { o -> have[o] = (have[o] ?: 0) - l.qty }
        for (l in gets) meta[l.cardId]?.oracleIdx?.takeIf { o -> o in giving }?.let { o -> have[o] = (have[o] ?: 0) + l.qty }
        return lists.flatMap { l ->
            val need = HashMap<Int, Int>()
            for (e in l.entries) if (e.board != "maybe") printing[e.cardId]?.oracleIdx?.takeIf { it in giving }?.let { o -> need[o] = (need[o] ?: 0) + e.qty }
            need.mapNotNull { (o, n) -> val left = maxOf(have[o] ?: 0, 0); if (n > left) Conflict(l, o, n - left) else null }
        }
    }

    fun run(remove: List<Conflict>) {
        conflicts = null
        busy = true
        error = null
        scope.launch {
            runCatching {
                saveJob?.cancel()
                val saved = TradesStore.save(trade, partner.trim().ifEmpty { null }, gives, gets)
                TradesStore.confirm(saved)
                trade = TradesStore.trade(saved.id) ?: saved
                // Take the missing copies out of each list, sideboard first.
                val db = CatalogStore.db
                if (db != null) for (c in remove) {
                    var left = c.short
                    val entries = c.list.entries.filter { it.board != "maybe" }.sortedByDescending { it.board == "side" }
                    val printing = db.printings(entries.map { it.cardId }.toSet())
                    for (e in entries) {
                        if (left <= 0) break
                        if (printing[e.cardId]?.oracleIdx != c.oracleIdx) continue
                        val n = minOf(left, e.qty)
                        ListsStore.add(c.list.id, e.cardId, e.board, -n, e.finish)
                        left -= n
                    }
                }
            }.onFailure { error = it.message }
            busy = false
        }
    }

    T1Screen {
        Bar(partner.trim().ifEmpty { "Trade" }, subtitle = if (confirmed) "Confirmed" else "Draft", onBack = onBack) {
            if (trade != null && !confirmed) BarAction("Delete") { askDelete = true }
        }
        error?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        if (confirmed) { if (partner.isNotEmpty()) ListRow("With", partner) }
        else Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
            T1TextField(partner, { partner = it.take(80) }, label = "Trading with", placeholder = "Name")
        }
        Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            listOf(true, false).forEach { give ->
                val lines = if (give) gives else gets
                Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    val v = PriceBook.text(sum(lines))
                    Section("${if (give) "You give" else "You get"} · ${lines.sumOf { it.qty }}")
                    if (v != null) Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 12.dp, vertical = 6.dp)) { Label(v, color = T1.text) }
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        lines.forEach { l ->
                            val p = meta[l.cardId]
                            TradeCell(p, p?.let { names[it.oracleIdx] } ?: "Card",
                                listOfNotNull(p?.setLabel, Finish.of(l.finish)?.label, l.condition, PriceBook.text(PriceBook.usd(l.cardId, l.finish).also { pricesVersion })),
                                l.qty) { if (!confirmed) editing = give to l.key }
                        }
                    }
                    if (!confirmed) {
                        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            SmallAction("Add", Modifier.weight(1f)) { picking = give }
                            SmallAction("Scan", Modifier.weight(1f)) { scanning = give }
                        }
                    }
                }
            }
        }
        val g = sum(gives); val r = sum(gets)
        ListRow("Market value", "Give ${PriceBook.text(g) ?: "—"} · get ${PriceBook.text(r) ?: "—"} · TCGplayer") {
            if (g != null && r != null) Text((if (r - g >= 0) "+" else "−") + (PriceBook.text(kotlin.math.abs(r - g)) ?: ""),
                color = T1.text, fontFamily = T1.mono, fontSize = 15.sp)
        }
        if (!confirmed) BigAction("Confirm trade", enabled = (gives.isNotEmpty() || gets.isNotEmpty()) && cat.phase == "ready", busy = busy, accent = true) {
            val c = findConflicts()
            if (c.isEmpty()) run(emptyList()) else conflicts = c
        }
    }

    editing?.let { (give, key) ->
        val l = (if (give) gives else gets).firstOrNull { it.key == key }
        if (l == null) { editing = null; return@let }
        val p = meta[l.cardId]
        val have = col.items[l.key]?.qty ?: 0
        val items = buildList {
            add(T1MenuItem("One more", enabled = !give || l.qty < have) { update(give, key, l.copy(qty = l.qty + 1)) })
            add(T1MenuItem("One fewer", enabled = l.qty > 1) { update(give, key, l.copy(qty = l.qty - 1)) })
            if (!give) {
                p?.finishList?.filter { it.wire != l.finish }?.forEach { f -> add(T1MenuItem("Make it ${f.label.lowercase()}") { update(give, key, l.copy(finish = f.wire)) }) }
                Conditions.all.filter { it != l.condition }.forEach { c -> add(T1MenuItem("Condition: ${Conditions.name(c)}") { update(give, key, l.copy(condition = c)) }) }
            }
            add(T1MenuItem("Remove", danger = true) { update(give, key, null) })
        }
        T1Menu(p?.let { names[it.oracleIdx] }, items) { editing = null }
    }
    conflicts?.let { c ->
        T1Menu("Cards in your decks: " + c.joinToString(", ") { "${names[it.oracleIdx] ?: "a card"} in ${it.list.name}" }, listOf(
            T1MenuItem("Remove them from the lists") { run(c) },
            T1MenuItem("Keep them listed (shown missing)") { run(emptyList()) },
        )) { conflicts = null }
    }
    if (askDelete) {
        T1Menu("Delete this trade?", listOf(T1MenuItem("Delete", danger = true) {
            trade?.let { t -> scope.launch { TradesStore.delete(t) } }
            onBack()
        })) { askDelete = false }
    }
    picking?.let { give ->
        TradePickOverlay(give, onPick = { add(give, it) }, onClose = { picking = null })
    }
    scanning?.let { give ->
        CardScanOverlay(
            title = if (give) "Scan what you give" else "Scan what you get",
            doneLabel = "Add",
            owned = if (give) ownedFinishes() else null,
            onDone = { cards ->
                for (c in cards) {
                    val condition = if (give) col.items.values.filter { it.cardId == c.printing.cardId && it.finish == c.finish }
                        .maxByOrNull { it.qty }?.condition ?: "NM" else c.condition
                    add(give, TradeLine(c.printing.cardId, c.finish, condition, "en", 1))
                }
                scanning = null
            },
            onCancel = { scanning = null },
        )
    }
}

@Composable
private fun TradeCell(p: CatalogPrinting?, name: String, detail: List<String>, qty: Int, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().background(T1.surface).clickable(onClick = onClick).padding(horizontal = 8.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        CardArt(p, 28.dp)
        Column(Modifier.weight(1f)) {
            Text(name, color = T1.text, fontFamily = T1.mono, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            detail.forEach { Label(it) }
        }
        Text("$qty", color = T1.text, fontFamily = T1.mono, fontSize = 15.sp)
    }
}

@Composable
private fun SmallAction(text: String, modifier: Modifier, onClick: () -> Unit) {
    Box(modifier.background(T1.surface).clickable(onClick = onClick).padding(vertical = 14.dp), contentAlignment = Alignment.Center) {
        Label(text, color = T1.text)
    }
}

/** Search for a card to add to one side. Giving: only copies you own. Getting: any card (default printing, NM). */
@Composable
private fun TradePickOverlay(give: Boolean, onPick: (TradeLine) -> Unit, onClose: () -> Unit) {
    val col by CollectionStore.state.collectAsState()
    var query by remember { mutableStateOf("") }
    var added by remember { mutableStateOf<String?>(null) }
    var rows by remember { mutableStateOf<List<Triple<TradeLine, CatalogPrinting?, String>>>(emptyList()) }
    LaunchedEffect(query, col.version) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        delay(120)
        val q = query
        rows = withContext(Dispatchers.Default) {
            if (give) {
                val items = col.items.values.toList()
                val p = db.printings(items.map { it.cardId }.toSet())
                val o = db.oracles(p.values.map { it.oracleIdx }.toSet())
                val n = CardName.norm(q)
                items.mapNotNull { it ->
                    val pr = p[it.cardId] ?: return@mapNotNull null
                    val or = o[pr.oracleIdx] ?: return@mapNotNull null
                    if (n.isNotEmpty() && !or.norm.contains(n)) null else Triple(TradeLine(it.cardId, it.finish, it.condition, it.lang, 1), pr, or.name)
                }.sortedBy { it.third }.take(200)
            } else {
                val hits = db.search(q)
                val covers = db.covers(hits.map { it.idx })
                hits.mapNotNull { o -> covers[o.idx]?.let { p -> Triple(TradeLine(p.cardId, (p.finishList.firstOrNull() ?: Finish.Nonfoil).wire), p, o.name) } }
            }
        }
    }
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar(if (give) "Add what you give" else "Add what you get", subtitle = added, onBack = onClose)
                Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
                    T1TextField(query, { query = it }, placeholder = if (give) "Search your collection" else "Lightning Bolt")
                }
                Hairlines(Modifier.weight(1f)) {
                    items(rows, key = { it.first.key }) { (line, p, name) ->
                        CardRow(p, name, if (give) listOfNotNull(p?.setLabel, Finish.of(line.finish)?.label, line.condition).joinToString(" · ") else p?.setLabel,
                            onClick = { onPick(line); added = "Added $name" }) {
                            if (give) Text("${col.items[line.key]?.qty ?: 0}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                        }
                    }
                }
                BigAction("Done") { onClose() }
            }
        }
    }
}
