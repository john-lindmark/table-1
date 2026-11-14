package site.table1.events.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.util.Locale

/*
 * Entry fees and prizes (contract/entry-fees-2026-11-13.md): what the server answers and every wording and sum, once.
 * The rules pass testdata/leagues/cases.json (reference make_cases.py: money, fee_line, pay_tag, payout_presets,
 * payout_words, prize_at, pool), the file iOS and the web pass too. Plain Kotlin, so EventExtrasTest runs without
 * Android. Table 1 never holds money: the host is the seller on their own Stripe account.
 */

/** Each place up to [through] takes [percent] of the pool. */
@Serializable
data class PayoutBracket(val through: Int, val percent: Double)

/** What the host keeps before prizes: none | flat (cents) | percent. */
@Serializable
data class HostKeep(val kind: String = "none", val value: Int = 0)

@Serializable
data class EventFee(
    @SerialName("amount_cents") val amountCents: Int = 0,
    val currency: String = "usd",
    /** door | app | either */
    @SerialName("pay_mode") val payMode: String = "door",
    /** A player's own full refund until this many hours before the start; null = ask the organizer. */
    @SerialName("refund_hours") val refundHours: Int? = null,
    @SerialName("host_keep") val hostKeep: HostKeep = HostKeep(),
    @SerialName("added_cents") val addedCents: Int = 0,
    val payout: List<PayoutBracket> = emptyList(),
    /** What each paid entry owes the event's league (0 outside a league and for a season's final). */
    @SerialName("league_cut_cents") val leagueCutCents: Int = 0,
) {
    val takesAppPayments: Boolean get() = payMode == "app" || payMode == "either"
}

@Serializable
data class MoneyPool(
    val entries: Int = 0,
    @SerialName("gross_cents") val grossCents: Int = 0,
    @SerialName("league_cut_cents") val leagueCutCents: Int = 0,
    @SerialName("host_keep_cents") val hostKeepCents: Int = 0,
    @SerialName("added_cents") val addedCents: Int = 0,
    @SerialName("pool_cents") val poolCents: Int = 0,
)

/** A signed-in player's own payment. [status]: unpaid | pending | paid | refunded; [method]: app | door | comp | null. */
@Serializable
data class MyPayment(
    @SerialName("participant_id") val participantId: String? = null,
    val status: String = "unpaid",
    val method: String? = null,
    @SerialName("amount_cents") val amountCents: Int = 0,
    @SerialName("can_pay") val canPay: Boolean = false,
    @SerialName("can_refund") val canRefund: Boolean = false,
)

@Serializable
data class Prize(
    @SerialName("participant_id") val participantId: String,
    @SerialName("user_id") val userId: String? = null,
    val name: String = "",
    val place: Int = 0,
    @SerialName("amount_cents") val amountCents: Int = 0,
    val custom: Boolean = false,
    val paid: Boolean = false,
    @SerialName("paid_how") val paidHow: String? = null,
)

/** One player's payment as the organizer gets it. */
@Serializable
data class PlayerPayment(
    @SerialName("participant_id") val participantId: String,
    @SerialName("user_id") val userId: String? = null,
    val name: String = "",
    val status: String = "unpaid",
    val method: String? = null,
    @SerialName("amount_cents") val amountCents: Int = 0,
)

@Serializable
data class StripeState(val connected: Boolean = false, val ready: Boolean = false)

@Serializable
data class MoneyOrganizer(val stripe: StripeState = StripeState(), val players: List<PlayerPayment> = emptyList(), val unpaid: Int = 0)

/** event_money: `{fee: null}` for an event with no fee. */
@Serializable
data class EventMoney(
    val fee: EventFee? = null,
    @SerialName("app_ready") val appReady: Boolean = false,
    val pool: MoneyPool? = null,
    val me: MyPayment? = null,
    val prizes: List<Prize> = emptyList(),
    val organizer: MoneyOrganizer? = null,
) {
    fun payment(participantId: String): PlayerPayment? = organizer?.players?.firstOrNull { it.participantId == participantId }
}

@Serializable
data class EventFeeSet(val fee: EventFee? = null)

/** payments_account, and the payments function's connect_status. */
@Serializable
data class PaymentsAccount(
    val connected: Boolean = false,
    val ready: Boolean = false,
    val payouts: Boolean = false,
    @SerialName("details_submitted") val detailsSubmitted: Boolean = false,
    @SerialName("disabled_reason") val disabledReason: String? = null,
    /** Payments are open to this account (§ 1 "Hidden for now"); absent from an older server = false. */
    val enabled: Boolean = false,
) {
    /** `NOT CONNECTED` / `FINISH SETTING UP` / `READY`. */
    val state: String get() = if (!connected) "Not connected" else if (!ready) "Finish setting up" else "Ready"
}

/** The payments function's `{url}` (onboarding, the dashboard, checkout) or `{error}`. */
@Serializable
data class PaymentsUrl(val url: String? = null, val error: String? = null)

@Serializable
data class RefundResult(val refunded: Boolean = false, @SerialName("amount_cents") val amountCents: Int = 0, val error: String? = null)

@Serializable
data class PrizesSet(@SerialName("total_cents") val totalCents: Int = 0, @SerialName("pool_cents") val poolCents: Int = 0)

/** league_money: everyone gets the cut and the pool; the league's organizers also what each event owes. */
@Serializable
data class LeagueMoney(
    @SerialName("entry_cut_cents") val entryCutCents: Int = 0,
    @SerialName("pool_cents") val poolCents: Int = 0,
    @SerialName("received_cents") val receivedCents: Int? = null,
    val events: List<Due>? = null,
) {
    @Serializable
    data class Due(
        @SerialName("event_id") val eventId: String,
        val name: String = "",
        val entries: Int = 0,
        @SerialName("owed_cents") val owedCents: Int = 0,
        @SerialName("received_cents") val receivedCents: Int = 0,
    )
}

object Fees {
    /** `$25`, `$7.50`, `$1,400`: whole dollars lose their cents. */
    fun money(cents: Long): String {
        val a = Math.abs(cents)
        val part = a % 100
        return (if (cents < 0) "-" else "") + "$" + "%,d".format(Locale.US, a / 100) + if (part != 0L) ".%02d".format(Locale.US, part) else ""
    }

    fun money(cents: Int): String = money(cents.toLong())

    /** A typed amount (`25`, `7.50`, `$1,400`) as cents; null when it isn't one. */
    fun cents(text: String): Int? {
        val t = text.trim().removePrefix("$").replace(",", "")
        if (t.isEmpty() || !Regex("""\d{0,7}(\.\d{0,2})?""").matches(t) || t == ".") return null
        val whole = t.substringBefore(".").ifEmpty { "0" }.toInt()
        val part = t.substringAfter(".", "").padEnd(2, '0').toInt()
        return whole * 100 + part
    }

    /** An amount as its field shows it: `25`, `7.50`; blank for 0. */
    fun field(cents: Int): String = if (cents == 0) "" else money(cents).removePrefix("$").replace(",", "")

    val payModes = listOf("door" to "At the door", "app" to "In the app", "either" to "Either")
    private val payModeWords = mapOf("door" to "DOOR", "app" to "APP", "either" to "APP OR DOOR")

    /** `NONE`, `FREE`, `$25 · APP OR DOOR`. */
    fun feeLine(fee: EventFee?): String = when {
        fee == null -> "NONE"
        fee.amountCents == 0 -> "FREE"
        else -> "${money(fee.amountCents)} · ${payModeWords[fee.payMode] ?: "DOOR"}"
    }

    /** `PAID · APP`, `PAID · DOOR`, `COMP`, `UNPAID`, `PENDING`, `REFUNDED`. */
    fun payTag(status: String, method: String?): String = when (status) {
        "paid" -> if (method == "comp") "COMP" else "PAID · ${if (method == "door") "DOOR" else "APP"}"
        "pending" -> "PENDING"
        "refunded" -> "REFUNDED"
        else -> "UNPAID"
    }

    /** A player's own paid line: `PAID`, `PAID AT THE DOOR`, `COMP`. */
    fun paidWord(method: String?): String = when (method) { "door" -> "PAID AT THE DOOR"; "comp" -> "COMP"; else -> "PAID" }

    /** Refunds: until N hours before the start, or ask the organizer (null). */
    val refunds: List<Pair<Int?, String>> = listOf(48 to "Until 48 h before", 24 to "24 h before", 0 to "Until it starts", null to "Ask me")

    fun refundWords(hours: Int?): String = refunds.firstOrNull { it.first == hours }?.second ?: hours?.let { "Until $it h before" } ?: "Ask me"

    val payoutPresets: Map<String, List<PayoutBracket>> = linkedMapOf(
        "winner" to listOf(PayoutBracket(1, 100.0)),
        "top2" to listOf(PayoutBracket(1, 65.0), PayoutBracket(2, 35.0)),
        "top4" to listOf(PayoutBracket(1, 40.0), PayoutBracket(2, 25.0), PayoutBracket(4, 17.5)),
        "top8" to listOf(PayoutBracket(1, 30.0), PayoutBracket(2, 20.0), PayoutBracket(4, 12.5), PayoutBracket(8, 6.25)),
    )

    val presetLabels = listOf("winner" to "Winner takes all", "top2" to "Top 2", "top4" to "Top 4", "top8" to "Top 8", "custom" to "Custom brackets")

    /** winner | top2 | top4 | top8 | custom (also for no prizes yet). */
    fun preset(payout: List<PayoutBracket>): String = payoutPresets.entries.firstOrNull { it.value == payout }?.key ?: "custom"

    /** `17.5%`, `40%`. */
    fun pct(v: Double): String =
        (if (v == Math.floor(v) && !v.isInfinite()) v.toLong().toString() else java.math.BigDecimal(v.toString()).stripTrailingZeros().toPlainString()) + "%"

    /** `1st 40% · 2nd 25% · 3rd to 4th 17.5% each`; `No prizes set`. */
    fun payoutWords(payout: List<PayoutBracket>): String {
        val parts = mutableListOf<String>()
        var last = 0
        for (b in payout) {
            val t = b.through
            parts += (if (t == last + 1) Leagues.ordinal(t) else "${Leagues.ordinal(last + 1)} to ${Leagues.ordinal(t)}") + " " + pct(b.percent) +
                if (t > last + 1) " each" else ""
            last = t
        }
        return parts.joinToString(" · ").ifEmpty { "No prizes set" }
    }

    /** The share of the pool the table hands out; it can't pass 100. */
    fun payoutTotal(payout: List<PayoutBracket>): Double {
        var total = 0.0
        var last = 0
        for (b in payout) {
            total += b.percent * (b.through - last)
            last = b.through
        }
        return total
    }

    /** A place's prize at a pool: its bracket's percent, split evenly among [share] (a team's members). */
    fun prizeAt(payout: List<PayoutBracket>, poolCents: Int, place: Int, share: Int = 1): Int {
        val b = payout.firstOrNull { it.through >= place } ?: return 0
        return (poolCents * b.percent / 100 / share).toInt()
    }

    /** Paid entries less the league's cut and the host's share (flat: that amount; percent: of what's left after the
     *  league), plus added money. */
    fun pool(entries: Int, amountCents: Int, cutCents: Int, keepKind: String, keepValue: Int, addedCents: Int): MoneyPool {
        val gross = entries * amountCents
        val league = entries * minOf(cutCents, amountCents)
        val keep = when (keepKind) {
            "flat" -> minOf(keepValue, gross - league)
            "percent" -> ((gross - league) * keepValue.toDouble() / 100).toInt()
            else -> 0
        }
        return MoneyPool(entries, gross, league, keep, addedCents, maxOf(0, gross - league - keep) + addedCents)
    }

    /** Each place the table pays, with its prize at the pool as it stands: `1st` → cents. */
    fun places(payout: List<PayoutBracket>, poolCents: Int): List<Pair<String, Int>> {
        val out = mutableListOf<Pair<String, Int>>()
        var last = 0
        for (b in payout) {
            val label = if (b.through == last + 1) Leagues.ordinal(b.through) else "${Leagues.ordinal(last + 1)} to ${Leagues.ordinal(b.through)}"
            out += label to prizeAt(payout, poolCents, b.through)
            last = b.through
        }
        return out
    }

    /** What the host keeps, in words: `Nothing`, `$20`, `10%`. */
    fun keepWords(k: HostKeep): String = when (k.kind) { "flat" -> money(k.value); "percent" -> "${k.value}%"; else -> "Nothing" }

    /** How a prize was handed over: event_prize_mark's `p_how` is exactly one of these. */
    val paidHows = listOf("cash" to "Cash", "store credit" to "Store credit", "other" to "Other")

    /** `PAID · CASH`, `PAID · STORE CREDIT`, and plain `PAID` for other. */
    fun prizePaidTag(how: String?): String = when (how) { "cash" -> "PAID · CASH"; "store credit" -> "PAID · STORE CREDIT"; else -> "PAID" }

    /** event_fee_set's `p_fee`, every key. */
    fun json(fee: EventFee): JsonObject = buildJsonObject {
        put("amount_cents", fee.amountCents)
        put("pay_mode", if (fee.amountCents == 0) "door" else fee.payMode)
        if (fee.refundHours == null) put("refund_hours", JsonNull) else put("refund_hours", fee.refundHours)
        putJsonObject("host_keep") { put("kind", fee.hostKeep.kind); put("value", fee.hostKeep.value) }
        put("added_cents", fee.addedCents)
        putJsonArray("payout") { fee.payout.forEach { b -> add(buildJsonObject { put("through", b.through); put("percent", b.percent) }) } }
    }

    /** What a bad fee says before it's sent; null when it can be saved. */
    fun problem(fee: EventFee): String? = when {
        fee.amountCents != 0 && fee.amountCents !in 50..100000 -> "The fee is $0.50 to $1,000, or 0 for a free event with prizes"
        fee.hostKeep.kind == "percent" && fee.hostKeep.value !in 0..100 -> "You keep 0 to 100%"
        payoutTotal(fee.payout) > 100.0 -> "The prizes add up to ${pct(payoutTotal(fee.payout))} of the pool"
        fee.payout.zipWithNext().any { (a, b) -> b.through <= a.through } -> "Each bracket ends after the one before"
        else -> null
    }

    /** "4 players haven't paid. Pair anyway?" */
    fun unpaidQuestion(unpaid: Int): String = "$unpaid player${if (unpaid == 1) " hasn't" else "s haven't"} paid. Pair anyway?"

    const val NOT_SET_UP = "Payments aren't set up yet"
    const val GOES_TO_STRIPE = "Entry fees go straight to your Stripe account."

    /** The payments function without Table 1's Stripe keys (503), or not deployed (404): show the plain line. */
    fun notSetUp(error: Throwable): Boolean {
        val text = generateSequence(error) { it.cause }.take(4).joinToString(" ") { "${it.message} $it" }
        return "aren't set up" in text || "503" in text || "NOT_FOUND" in text || "Requested function was not found" in text || Leagues.isMissing(error)
    }
}
