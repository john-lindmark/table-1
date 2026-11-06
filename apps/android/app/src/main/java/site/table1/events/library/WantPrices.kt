package site.table1.events.library

import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.util.Telemetry
import kotlin.math.abs
import kotlin.math.roundToLong

/* Want prices (contract/want-prices-2026-10-26.md): each want's price now, a week back and its 30-day average, the
   trend shown on Wanted rows, and the account's price alerts switch. Rules shared with iOS and web in
   testdata/want-prices/cases.json. Android has no push yet (FCM), but the switch is the account's. */

/** One want's prices from wants_prices: the cheapest near-mint price among what the want takes. */
@Serializable
data class WantPrice(
    @SerialName("oracle_id") val oracleId: String,
    @SerialName("card_id") val cardId: String? = null,
    val finish: String? = null,
    val now: Double? = null,
    @SerialName("now_card_id") val nowCardId: String? = null,
    @SerialName("now_finish") val nowFinish: String? = null,
    val then: Double? = null,
    @SerialName("then_days") val thenDays: Int? = null,
    val avg30: Double? = null,
) {
    val key get() = wantKey(oracleId, cardId, finish)
}

@Serializable
private data class WantPricesAnswer(val alerts: Boolean, val items: List<WantPrice>)

@Serializable
private data class WantAlertsAnswer(val alerts: Boolean)

/** The shared rules. Whole cents throughout, so a half percent rounds the same on every platform. */
object WantPrices {
    data class Trend(val dir: String, val text: String)

    private fun cents(v: Double) = (v * 100).roundToLong()

    fun money(v: Double): String {
        val c = cents(v)
        return "$${c / 100}.${(c % 100).toString().padStart(2, '0')}"
    }

    private fun period(days: Int) = if (days >= 7) "this week" else if (days == 1) "since yesterday" else "in $days days"

    /** Now against the oldest price of the last 7 days, [days] ago. Null without both prices. */
    fun trend(now: Double?, then: Double?, days: Int?): Trend? {
        if (now == null || then == null || days == null || days < 1) return null
        val n = cents(now)
        val t = cents(then)
        if (t <= 0) return null
        val diff = n - t
        val pct = (abs(diff) * 200 + t) / (2 * t)
        if (abs(diff) < 5 || pct == 0L) return Trend("flat", "Flat ${period(days)}")
        return if (diff > 0) Trend("up", "▲ $pct% ${period(days)}") else Trend("down", "▼ $pct% ${period(days)}")
    }

    /** A Wanted row's detail: which printing · Max $X · Now $Y (From for any printing). The trend has its own line. */
    fun detail(which: String, max: Double?, now: Double?, any: Boolean): String =
        listOfNotNull(which.ifEmpty { null }, max?.let { "Max ${money(it)}" }, now?.let { "${if (any) "From" else "Now"} ${money(it)}" })
            .joinToString(" · ")
}

/** [alerts] null until loaded. */
data class WantPricesState(val items: Map<String, WantPrice> = emptyMap(), val alerts: Boolean? = null, val error: String? = null) {
    fun trend(w: Want) = items[w.key]?.let { WantPrices.trend(it.now, it.then, it.thenDays) }
}

object WantPricesStore {
    private val _state = MutableStateFlow(WantPricesState())
    val state: StateFlow<WantPricesState> = _state.asStateFlow()
    private val rpc get() = T1App.supabase.postgrest

    fun stop() { _state.value = WantPricesState() }

    suspend fun load() {
        runCatching { rpc.rpc("wants_prices").decodeAs<WantPricesAnswer>() }
            .onSuccess { a ->
                _state.update { WantPricesState(a.items.associateBy { it.key }, a.alerts) }
                val trends = a.items.mapNotNull { WantPrices.trend(it.now, it.then, it.thenDays) }
                Telemetry.capture("want_prices_loaded", mapOf("wants" to a.items.size, "with_trend" to trends.size,
                    "down" to trends.count { it.dir == "down" }, "up" to trends.count { it.dir == "up" }))
            }
            .onFailure { e -> _state.update { it.copy(error = e.message) } }
    }

    suspend fun setAlerts(on: Boolean) {
        val was = _state.value.alerts
        _state.update { it.copy(alerts = on) }
        runCatching { rpc.rpc("want_alerts_set", buildJsonObject { put("p_on", on) }).decodeAs<WantAlertsAnswer>() }
            .onSuccess { a ->
                _state.update { it.copy(alerts = a.alerts) }
                Telemetry.capture("want_alerts_changed", mapOf("on" to a.alerts))
            }
            .onFailure { e -> _state.update { it.copy(alerts = was, error = e.message) } }
    }
}

/* Buy on TCGplayer (contract/tcgplayer-cart-2026-10-26.md): wants or Missing as TCGplayer Mass Entry links, and a
   want for a printing as a link to its product page (§ Printings). The server writes the links (names, parts,
   affiliate wrapper); the app opens them. */
@Serializable
data class TCGplayerCartProduct(val name: String, val set: String, val number: String, val qty: Int, val url: String)

@Serializable
data class TCGplayerCartAnswer(
    val enabled: Boolean, val lines: Int = 0, val unknown: Int = 0, val urls: List<String> = emptyList(),
    val products: List<TCGplayerCartProduct> = emptyList(),
)

object TCGplayerCart {
    /** One card: a printing ([cardId]) or any printing ([oracleId] alone). */
    data class Item(val oracleId: String? = null, val cardId: String? = null, val qty: Int)

    data class Entry(val title: String, val detail: String, val url: String)

    /** Parts as menu labels: "Part 1 of 3". */
    fun partTitle(i: Int, n: Int) = "Part ${i + 1} of $n"

    /** What a tap opens straight away: the only link there is (testdata/tcgplayer-cart/cases.json). */
    fun direct(a: TCGplayerCartAnswer): String? =
        if (a.urls.size + a.products.size == 1) a.urls.firstOrNull() ?: a.products.first().url else null

    /** The Buy on TCGplayer menu when there's more than one link: Mass Entry first, then each product page. */
    fun menu(a: TCGplayerCartAnswer): List<Entry> {
        if (direct(a) != null) return emptyList()
        val n = a.urls.size
        val parts = a.urls.mapIndexed { i, u ->
            when {
                a.products.isEmpty() -> Entry(partTitle(i, n), "Adds to the same cart", u)
                n == 1 -> Entry("Any printing", "Into one cart, then Optimize", u)
                else -> Entry("Any printing · part ${i + 1} of $n", "Adds to the same cart", u)
            }
        }
        return parts + a.products.map {
            Entry(it.name, "${it.set} ${it.number} · ${it.qty} ${if (it.qty == 1) "copy" else "copies"} · its own page", it.url)
        }
    }

    /** [from] tags the affiliate link with the screen (wants / missing / deck / cube / card); the server adds the platform.
     *  [products] sends printings to their product pages; off, every card goes into Mass Entry by name. */
    suspend fun links(items: List<Item>, from: String? = null, products: Boolean = true): TCGplayerCartAnswer =
        T1App.supabase.postgrest.rpc("tcgplayer_cart", buildJsonObject {
            put("p_items", kotlinx.serialization.json.buildJsonArray {
                for (i in items) add(buildJsonObject {
                    if (i.oracleId != null) put("oracle_id", i.oracleId)
                    if (i.cardId != null) put("card_id", i.cardId)
                    put("qty", i.qty)
                })
            })
            put("p_products", products)
            if (from != null) put("p_from", from)
        }).decodeAs()

    /** Whether the Buy on TCGplayer rows show: the server's switch (an empty cart answers it). */
    suspend fun enabled(): Boolean = runCatching { links(emptyList()).enabled }.getOrDefault(false)
}
