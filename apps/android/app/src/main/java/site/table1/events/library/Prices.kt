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
 * USD is TCGplayer's market price as Scryfall publishes it; EUR is Cardmarket's. Prices are near mint; [usd] prices a
 * copy in its condition ([Conditions.price]).
 */
object PriceBook {
    /** card id → [usd, usd_foil, usd_etched, eur, eur_foil, converted] */
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

    /** Whether prices for this printing have come back (with or without one). */
    fun has(cardId: String): Boolean = synchronized(this) { cardId in rows }

    /** One copy's USD price in a finish and condition, null when there's no market price. */
    fun usd(cardId: String, finish: String, condition: String = "NM"): Double? {
        val r = synchronized(this) { rows[cardId] } ?: return null
        return Conditions.price(r.getOrNull(when (finish) { "foil" -> 1; "etched" -> 2; else -> 0 }), condition)
    }

    /** Whether the USD price of this finish is Cardmarket's converted (contract/converted-prices-2026-10-28.md). */
    fun converted(cardId: String, finish: String): Boolean = converted(synchronized(this) { rows[cardId] } ?: emptyList(), finish)

    /** A card_prices_get row without its id: the seventh element is a bitmask of converted finishes (1 nonfoil,
     *  2 foil); rows from older servers have six. */
    fun converted(row: List<Double?>, finish: String): Boolean {
        val bit = when (finish) { "foil" -> 2; "etched" -> 0; else -> 1 }
        val mask = row.getOrNull(5)?.toInt() ?: 0
        return bit > 0 && mask and bit != 0
    }

    /** "≈ $7,992.55", plus " · from Cardmarket" where there's room to say so. */
    fun marked(text: String?, converted: Boolean, source: Boolean = false): String? =
        if (text == null || !converted) text else "≈ $text" + if (source) " · from Cardmarket" else ""

    fun text(usd: Double?): String? = usd?.let {
        NumberFormat.getCurrencyInstance().apply { currency = Currency.getInstance("USD"); maximumFractionDigits = 2 }.format(it)
    }

    /** A copy's price in its condition, saying what near mint would be when it isn't: "$9.00 · LP (NM $10.00)". */
    fun conditionText(nearMint: Double?, condition: String): String? {
        val price = text(Conditions.price(nearMint, condition)) ?: return null
        if (Conditions.percent(condition) == 100) return price
        return "$price · ${condition.uppercase()} (NM ${text(nearMint)})"
    }
}

/** NM, LP, MP, HP, DMG. */
object Conditions {
    val all = listOf("NM", "LP", "MP", "HP", "DMG")
    fun name(c: String) = when (c) {
        "NM" -> "Near mint"; "LP" -> "Lightly played"; "MP" -> "Moderately played"; "HP" -> "Heavily played"; "DMG" -> "Damaged"
        else -> c
    }

    /** The share of the near-mint price a copy in this condition is worth (contract/condition-prices-2026-10-24.md). */
    fun percent(condition: String): Int = when (condition.uppercase()) {
        "LP" -> 90; "MP" -> 75; "HP" -> 60; "DMG" -> 40
        else -> 100
    }

    /** One copy's price in its condition from the near-mint price: whole cents, half up, never below a cent. */
    fun price(nearMint: Double?, condition: String): Double? {
        if (nearMint == null) return null
        val cents = Math.round(nearMint * 100)
        if (cents <= 0) return nearMint
        return maxOf(1L, (cents * percent(condition) + 50) / 100) / 100.0
    }

    /** True when a is a better condition than b (NM before LP … DMG). */
    fun better(a: String, b: String): Boolean =
        all.indexOf(a).let { if (it < 0) all.size else it } < all.indexOf(b).let { if (it < 0) all.size else it }
}
