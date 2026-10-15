package site.table1.events.library

import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.put
import site.table1.events.T1App
import java.text.NumberFormat
import java.util.Currency

/**
 * Current market prices for printings (card_prices_get), fetched on demand and kept for the session.
 * USD is TCGplayer's market price as Scryfall publishes it; EUR is Cardmarket's. Prices are near mint.
 */
object PriceBook {
    /** card id → [usd, usd_foil, usd_etched, eur, eur_foil] */
    private val rows = HashMap<String, List<Double?>>()
    private val asked = HashSet<String>()
    private val _version = MutableStateFlow(0)
    /** Bumps whenever prices arrive. */
    val version: StateFlow<Int> = _version.asStateFlow()

    suspend fun load(ids: Collection<String>) {
        val missing = synchronized(this) { ids.toSet().filter { asked.add(it) } }
        if (missing.isEmpty()) return
        for (chunk in missing.chunked(5000)) {
            runCatching {
                T1App.supabase.postgrest.rpc("card_prices_get", buildJsonObject {
                    put("p_card_ids", buildJsonArray { chunk.forEach { add(it) } })
                }).decodeAs<List<JsonArray>>()
            }.onSuccess { got ->
                synchronized(this) {
                    for (r in got) rows[r[0].jsonPrimitive.content] = r.drop(1).map { if (it is JsonNull) null else it.jsonPrimitive.doubleOrNull }
                    for (id in chunk) if (id !in rows) rows[id] = emptyList()
                }
                _version.update { it + 1 }
            }.onFailure { synchronized(this) { asked.removeAll(chunk.toSet()) } } // try again next time
        }
    }

    /** One copy's USD price in a finish, null when there's no market price. */
    fun usd(cardId: String, finish: String): Double? {
        val r = synchronized(this) { rows[cardId] } ?: return null
        return r.getOrNull(when (finish) { "foil" -> 1; "etched" -> 2; else -> 0 })
    }

    fun text(usd: Double?): String? = usd?.let {
        NumberFormat.getCurrencyInstance().apply { currency = Currency.getInstance("USD"); maximumFractionDigits = 2 }.format(it)
    }
}

/** NM, LP, MP, HP, DMG. */
object Conditions {
    val all = listOf("NM", "LP", "MP", "HP", "DMG")
    fun name(c: String) = when (c) {
        "NM" -> "Near mint"; "LP" -> "Lightly played"; "MP" -> "Moderately played"; "HP" -> "Heavily played"; "DMG" -> "Damaged"
        else -> c
    }
}
