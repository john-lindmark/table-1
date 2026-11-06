package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
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
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* The Buy screen (contract/buy-2026-11-06.md): a deck, a cube, Wants or Missing as a TCGplayer cart, Moxfield's way:
   the options, the cards to buy by board, price − owned = total, then Buy on TCGplayer. Rules in BuyList.kt.
   [source] is a deck or cube id, "wants" or "missing". */

private data class BuyCard(val name: String, val oracleId: String?, val printing: CatalogPrinting?)

@Composable
fun BuyScreen(source: String, onBack: () -> Unit, onCard: (String) -> Unit) {
    val lists by ListsStore.state.collectAsState()
    val b by BindersStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val col by CollectionStore.state.collectAsState()
    val prices by WantPricesStore.state.collectAsState()
    val priceVersion by PriceBook.version.collectAsState()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val list = lists.lists.firstOrNull { it.id == source }
    val ownsOptions = source != "wants" && source != "missing"
    val isDeck = list?.kind == ListKind.Deck
    val family = when {
        source == "wants" || source == "missing" -> source
        list?.kind == ListKind.Cube -> "cube"
        else -> "deck"
    }
    var options by remember(family) { mutableStateOf(BuyList.stored(family)) }
    var tokens by remember(family) { mutableStateOf(BuyList.storedTokens(family)) }
    var base by remember { mutableStateOf<List<BuyList.Line>>(emptyList()) }
    var cards by remember { mutableStateOf<Map<String, BuyCard>>(emptyMap()) }
    var loaded by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf<List<TCGplayerCart.Entry>?>(null) }
    var boardsOpen by remember { mutableStateOf(false) }
    val holdings = rememberHoldings(base.map { it.cardId })

    LaunchedEffect(family) {
        Telemetry.screen("buy")
        Telemetry.capture("buy_opened", mapOf("from" to family))
        CatalogStore.load(userInitiated = true)
    }
    LaunchedEffect(source, lists.lists, b.version, col.version, cat.generation, prices.items) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val wants = b.liveWants
        val ls = lists.lists
        val owned = col.items.values.groupBy { ownKey(it.cardId, it.finish) }.mapValues { (_, v) -> v.sumOf { it.qty } }
        val out = withContext(Dispatchers.Default) {
            val lines: List<BuyList.Line> = when (source) {
                "wants" -> wants.mapNotNull { w ->
                    if (w.cardId != null) BuyList.Line(w.cardId, w.oracleId, board = "main", finish = w.finish ?: "nonfoil", qty = w.qty)
                    else {
                        val o = db.oracle(w.oracleId) ?: return@mapNotNull null
                        val drawn = prices.items[w.key]?.nowCardId ?: db.covers(listOf(o.idx))[o.idx]?.cardId ?: return@mapNotNull null
                        BuyList.Line(drawn, w.oracleId, any = true, board = "main", finish = w.finish ?: "nonfoil", qty = w.qty)
                    }
                }
                "missing" -> MissingView.lines(ls, Holdings(owned, db.cardKeys(owned.keys.map { it.substringBefore("|") }.toSet() + ls.flatMap { l -> l.entries.map { it.cardId } })),
                                               db.basicCardIds())
                    .map { BuyList.Line(it.cardId, board = "main", finish = it.finish, qty = it.short) }
                else -> {
                    val l = ls.firstOrNull { it.id == source }
                    if (l == null) emptyList() else {
                        val basics = db.basicCardIds()
                        val order = BuyList.BOARD_ORDER
                        val entries = l.entries.withIndex().sortedWith(compareBy({ order.indexOf(it.value.board).let { i -> if (i < 0) 9 else i } }, { it.index })).map { it.value }
                        val out = entries.map { BuyList.Line(it.cardId, board = it.board, finish = it.finish, qty = it.qty, basic = it.cardId in basics) }.toMutableList()
                        if (l.kind == ListKind.Deck) {
                            // The tokens the main deck, commander and sideboard make, one each, in their catalog printing.
                            val ps = db.printings(entries.filter { it.board != "maybe" }.map { it.cardId }.toSet())
                            val os = db.oracles(ps.values.map { it.oracleIdx }.toSet())
                            val seen = LinkedHashSet<Int>()
                            for (e in entries) if (e.board != "maybe") ps[e.cardId]?.let { os[it.oracleIdx] }?.tokens?.let { seen.addAll(it) }
                            val covers = db.covers(seen)
                            seen.mapNotNull { covers[it] }.forEach { out += BuyList.Line(it.cardId, board = "tokens", qty = 1) }
                        }
                        out
                    }
                }
            }
            val ps = db.printings(lines.map { it.cardId }.toSet())
            val os = db.oracles(ps.values.map { it.oracleIdx }.toSet())
            lines to lines.map { it.cardId }.distinct().associateWith { id ->
                val p = ps[id]
                val o = p?.let { os[it.oracleIdx] }
                BuyCard(o?.name ?: "Card not in local data yet", o?.oracleId, p)
            }
        }
        base = out.first
        cards = out.second
        loaded = true
        PriceBook.load(out.first.map { it.cardId }.toSet())
        if (source == "wants") WantPricesStore.load()
    }

    @Suppress("UNUSED_EXPRESSION") priceVersion
    val wants = b.liveWants
    val lines = base.map { l ->
        val now = if (l.any) wants.firstOrNull { it.oracleId == l.oracleId && it.cardId == null }?.let { prices.items[it.key]?.now } else null
        l.copy(unit = BuyList.cents(now ?: PriceBook.usd(l.cardId, l.finish)))
    }
    var effective = options
    if (!ownsOptions) effective = effective.copy(skipOwned = false, boards = setOf("main"))
    effective = effective.copy(boards = if (tokens && isDeck) effective.boards + "tokens" else effective.boards - "tokens")
    val rows = BuyList.rows(lines, holdings, effective)
    val t = BuyList.totals(rows)
    val boards = BuyList.BOARD_ORDER.filter { bd -> bd != "tokens" && lines.any { it.board == bd } }
    fun title(bd: String) = when (source) {
        "wants" -> "Wants"
        "missing" -> "Missing"
        else -> if (bd == "tokens") "Tokens" else list?.boardTitle(bd) ?: bd
    }
    fun set(name: String, v: Boolean, change: (BuyList.Options) -> BuyList.Options) {
        options = change(options)
        BuyList.save(family, name, v)
        Telemetry.capture("buy_option", mapOf("from" to family, "option" to name, "on" to v))
    }
    fun open(url: String) {
        runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))) }
            .onFailure { error = it.message }
    }
    fun buy() {
        val calls = BuyList.calls(rows, effective.exact)
        if (calls.isEmpty()) return
        busy = true
        error = null
        scope.launch {
            runCatching { BuyList.merge(calls.map { TCGplayerCart.links(it.items, family, it.products) }) }
                .onSuccess { a ->
                    Telemetry.capture("tcgplayer_cart_opened", mapOf("from" to family, "lines" to a.lines, "parts" to a.urls.size, "products" to a.products.size,
                        "skip" to effective.skipOwned, "any" to effective.anyPrinting, "exact" to effective.exact, "tokens" to ("tokens" in effective.boards)))
                    val direct = TCGplayerCart.direct(a)
                    val m = TCGplayerCart.menu(a)
                    when {
                        direct != null -> open(direct)
                        m.isEmpty() -> error = "Nothing to buy"
                        else -> menu = m
                    }
                }
                .onFailure { error = it.message }
            busy = false
        }
    }

    T1Screen {
        Bar("Buy", subtitle = list?.name, onBack = onBack)
        CatalogStatus(cat)
        error?.let { Notice(it, error = true) }
        Hairlines(Modifier.weight(1f)) {
            if (!loaded) item { ListRow("Loading the cards…") } else {
                item(key = "total") {
                    Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(BuyList.money(t.total), color = T1.accent, fontFamily = T1.mono, fontSize = 34.sp, fontWeight = FontWeight.SemiBold)
                        Label(listOfNotNull("${t.cards} cards", if (ownsOptions && effective.skipOwned) "${t.owned} owned" else null, "${t.buy} to buy",
                            if (t.unpriced > 0) "${t.unpriced} unpriced" else null).joinToString(" · "))
                    }
                }
                if (ownsOptions) {
                    item(key = "skip") {
                        ListRow("Skip cards I own", onClick = { set("skip", !options.skipOwned) { it.copy(skipOwned = !it.skipOwned) } }) {
                            T1Switch(options.skipOwned) { v -> set("skip", v) { it.copy(skipOwned = v) } }
                        }
                    }
                    if (options.skipOwned) item(key = "any") {
                        ListRow("Any printing I own counts", onClick = { set("any", !options.anyPrinting) { it.copy(anyPrinting = !it.anyPrinting) } }) {
                            T1Switch(options.anyPrinting) { v -> set("any", v) { it.copy(anyPrinting = v) } }
                        }
                    }
                }
                item(key = "exact") {
                    ListRow("Exact printings", onClick = { set("exact", !options.exact) { it.copy(exact = !it.exact) } }) {
                        T1Switch(options.exact) { v -> set("exact", v) { it.copy(exact = v) } }
                    }
                }
                if (isDeck) item(key = "tokens") {
                    fun flip(v: Boolean) {
                        tokens = v
                        BuyList.save(family, "tokens", v)
                        Telemetry.capture("buy_option", mapOf("from" to family, "option" to "tokens", "on" to v))
                    }
                    ListRow("Tokens", onClick = { flip(!tokens) }) { T1Switch(tokens) { flip(it) } }
                }
                if (ownsOptions && boards.size > 1) item(key = "boards") {
                    ListRow("Boards", boards.filter { it in options.boards }.joinToString(" · ") { title(it) }.ifEmpty { "None" }, onClick = { boardsOpen = true })
                }
                for (bd in BuyList.BOARD_ORDER) {
                    val inBoard = rows.filter { it.line.board == bd }
                    if (inBoard.isEmpty()) continue
                    val own = inBoard.sumOf { it.owned }
                    val buying = inBoard.filter { it.buy > 0 }
                    item(key = "s-$bd") { Section(listOfNotNull(title(bd), "${buying.sumOf { it.buy }} to buy", if (own > 0) "$own owned" else null).joinToString(" · ")) }
                    items(buying.withIndex().toList(), key = { "r-$bd-${it.index}" }) { (_, r) ->
                        val c = cards[r.line.cardId]
                        val detail = if (r.line.any) "Any printing"
                            else listOfNotNull(c?.printing?.setLabel, if (r.line.finish == "nonfoil") null else Finish.of(r.line.finish)?.label).joinToString(" · ")
                        CardRow(c?.printing, c?.name ?: "Card not in local data yet", detail.ifEmpty { null }, onClick = { c?.oracleId?.let(onCard) },
                            finish = r.line.finish, note = if (r.owned > 0) "Own ${r.owned} of ${r.line.qty}" else null) {
                            Text("${r.buy}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                        }
                    }
                }
                item(key = "total-s") { Section("Total") }
                item(key = "price") { ListRow("Price") { Text(BuyList.money(t.price), color = T1.text, fontFamily = T1.mono, fontSize = 15.sp) } }
                if (t.ownedValue > 0) item(key = "owned") {
                    ListRow("Owned") { Text("−" + BuyList.money(t.ownedValue), color = T1.text, fontFamily = T1.mono, fontSize = 15.sp) }
                }
                item(key = "sum") { ListRow("Total") { Text(BuyList.money(t.total), color = T1.accent, fontFamily = T1.mono, fontSize = 15.sp) } }
            }
        }
        val enabled = t.buy > 0 && !busy
        Box(Modifier.fillMaxWidth().height(54.dp).background(if (enabled) T1.surface else T1.disabled)
            .clickable(enabled = enabled) { buy() }.padding(top = 18.dp), contentAlignment = Alignment.TopCenter) {
            Text((if (busy) "Opening TCGplayer…" else "Buy on TCGplayer").uppercase(), color = if (enabled) T1.text else T1.muted,
                fontFamily = T1.mono, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 4.sp)
        }
    }
    if (boardsOpen) {
        T1Menu("Boards", boards.map { bd ->
            T1MenuItem(title(bd), selected = bd in options.boards) {
                val on = bd !in options.boards
                options = options.copy(boards = if (on) options.boards + bd else options.boards - bd)
                BuyList.saveBoards(family, options.boards)
                Telemetry.capture("buy_option", mapOf("from" to family, "option" to "board_$bd", "on" to on))
            }
        }) { boardsOpen = false }
    }
    menu?.let { m ->
        T1Menu("Buy on TCGplayer", m.map { e -> T1MenuItem("${e.title} · ${e.detail}") { open(e.url) } }) { menu = null }
    }
}

/** The Buy row on a deck or cube: copies to buy with the remembered options (tokens left out) and their price once in. */
@Composable
fun BuyRow(list: CardList, holdings: Holdings, onClick: () -> Unit) {
    val priceVersion by PriceBook.version.collectAsState()
    val basics = CatalogStore.basics
    val t = remember(list, holdings, priceVersion, basics) {
        val o = BuyList.stored(if (list.kind == ListKind.Cube) "cube" else "deck")
        BuyList.totals(BuyList.rows(list.entries.map {
            BuyList.Line(it.cardId, board = it.board, finish = it.finish, qty = it.qty, unit = BuyList.cents(PriceBook.usd(it.cardId, it.finish)), basic = it.cardId in basics)
        }, holdings, o))
    }
    ListRow("Buy", if (t.buy == 0) "You own every card" else "${t.buy} to buy" + (if (t.total > 0) " · ${BuyList.money(t.total)}" else ""), onClick = onClick)
}
