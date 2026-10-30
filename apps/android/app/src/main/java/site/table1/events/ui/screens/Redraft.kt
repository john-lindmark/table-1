package site.table1.events.ui.screens

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.sp
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.data.EventRow
import site.table1.events.library.CardRow
import site.table1.events.library.CardScanOverlay
import site.table1.events.library.CatalogPrinting
import site.table1.events.library.CatalogStore
import site.table1.events.library.Hairlines
import site.table1.events.library.PriceBook
import site.table1.events.library.ScannedCard
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* The redraft pile for a finished set draft (contract/event-night-2026-10-16.md § 6): anyone in the event scans cards
   in; the list runs most valuable first (TCGplayer market for the finish scanned) and stays with the event. Same as
   iOS RedraftView. */

@Serializable
data class RedraftCard(
    val id: String, @SerialName("card_id") val cardId: String, val finish: String, val name: String, val set: String,
    val cn: String, val usd: Double? = null, @SerialName("added_by") val addedBy: String = "", val mine: Boolean = false,
)

@Serializable
data class RedraftPile(val count: Int = 0, @SerialName("total_usd") val totalUsd: Double = 0.0, val cards: List<RedraftCard> = emptyList())

/** Set drafts (not cubes) get a redraft once the event is over. */
val EventRow.canRedraft: Boolean get() = (formatName ?: format) in setOf("draft", "team_draft") &&
    cubeName.isNullOrEmpty() && cubeUrl.isNullOrEmpty() && status in setOf("completed", "archived")

object Redraft {
    private val rpc get() = T1App.supabase.postgrest
    suspend fun list(eventId: String): RedraftPile = rpc.rpc("redraft_list", buildJsonObject { put("p_event_id", eventId) }).decodeAs()
    suspend fun add(eventId: String, cards: List<ScannedCard>): RedraftPile = rpc.rpc("redraft_add", buildJsonObject {
        put("p_event_id", eventId)
        put("p_cards", buildJsonArray { cards.take(200).forEach { c -> add(buildJsonObject { put("card_id", c.printing.cardId); put("finish", c.finish) }) } })
    }).decodeAs()
    suspend fun remove(id: String): RedraftPile = rpc.rpc("redraft_remove", buildJsonObject { put("p_id", id) }).decodeAs()
}

@Composable
fun RedraftScreen(eventId: String, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val cat by CatalogStore.state.collectAsState()
    var pile by remember { mutableStateOf<RedraftPile?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var scanning by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<RedraftCard?>(null) }
    LaunchedEffect(eventId) {
        Telemetry.screen("redraft")
        CatalogStore.load(userInitiated = true)
        runCatching { Redraft.list(eventId) }.onSuccess { pile = it; error = null }.onFailure { error = it.message }
    }
    val printings by produceState<Map<String, CatalogPrinting>>(emptyMap(), pile, cat.generation) {
        val db = CatalogStore.db ?: return@produceState
        val ids = pile?.cards?.map { it.cardId }.orEmpty()
        value = withContext(Dispatchers.Default) { db.printings(ids) }
    }
    val p = pile
    T1Screen {
        Bar("Redraft", p?.takeIf { it.count > 0 }?.let { "${it.count} ${if (it.count == 1) "card" else "cards"} · ${PriceBook.text(it.totalUsd) ?: ""}" }, onBack = onBack)
        Hairlines(Modifier.weight(1f)) {
            item { Row { Ghost(if (busy) "Adding…" else "Scan cards", enabled = !busy, accent = true) { scanning = true } } }
            error?.let { item { Notice(it, error = true) } }
            when {
                p == null -> item { Notice("Loading…") }
                p.cards.isEmpty() -> item { Notice("Scan the cards going into the redraft. They line up most valuable first so the table can see what's in the pile.") }
                else -> itemsIndexed(p.cards, key = { _, c -> c.id }) { i, c ->
                    val detail = listOfNotNull("${c.set.uppercase()} ${c.cn}", if (c.finish == "nonfoil") null else if (c.finish == "foil") "Foil" else "Etched",
                        if (c.mine) "You" else c.addedBy).joinToString(" · ")
                    CardRow(printings[c.cardId], "${i + 1}. ${c.name}", detail, onClick = { menuFor = c }, finish = c.finish) {
                        Text(PriceBook.text(c.usd) ?: "–", color = if (i == 0 && c.usd != null) T1.accent else T1.text, fontFamily = T1.mono, fontSize = 14.sp)
                    }
                }
            }
        }
    }
    if (scanning) CardScanOverlay("Scan the redraft", "Add", owned = null, onDone = { cards ->
        scanning = false
        if (cards.isEmpty()) return@CardScanOverlay
        busy = true
        scope.launch {
            runCatching { Redraft.add(eventId, cards) }
                .onSuccess { pile = it; error = null; Telemetry.capture("redraft_cards_added", mapOf("cards" to cards.size, "exact" to cards.count { it.exact })) }
                .onFailure { error = it.message }
            busy = false
        }
    }, onCancel = { scanning = false })
    menuFor?.let { c ->
        T1Menu(c.name, listOf(T1MenuItem("Remove from the pile", danger = true) {
            scope.launch {
                runCatching { Redraft.remove(c.id) }.onSuccess { pile = it; Telemetry.capture("redraft_card_removed") }.onFailure { error = it.message }
            }
        })) { menuFor = null }
    }
}
