package site.table1.events.ui.screens

import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.data.EventDemo
import site.table1.events.data.EventFee
import site.table1.events.data.EventMoney
import site.table1.events.data.Fees
import site.table1.events.data.HostKeep
import site.table1.events.data.LeagueMoney
import site.table1.events.data.Leagues
import site.table1.events.data.LeaguesDemo
import site.table1.events.data.PaymentsAccount
import site.table1.events.data.PayoutBracket
import site.table1.events.data.PlayerPayment
import site.table1.events.data.Prize
import site.table1.events.data.Repo
import site.table1.events.data.checkout
import site.table1.events.data.connectDashboard
import site.table1.events.data.connectStart
import site.table1.events.data.connectStatus
import site.table1.events.data.leagueMoney
import site.table1.events.data.leagueView
import site.table1.events.data.markLeagueDue
import site.table1.events.data.markPayment
import site.table1.events.data.markPrize
import site.table1.events.data.paymentsAccount
import site.table1.events.data.paymentsMessage
import site.table1.events.data.refund
import site.table1.events.data.setEventFee
import site.table1.events.data.setPrizes
import site.table1.events.openInBrowser
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Stepper
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled

/*
 * Entry fees and prizes (contract/entry-fees-2026-11-13.md Clients): Account → Payments, the fee in Setup → Details, the
 * fee and Prize pool on the event page, a player's Pay / pending / paid / refund, payment tags in the organizer's
 * Players lists, Results → Prizes, and a league's Prize pool, Cut per entry and Dues. Stripe's own pages (onboarding,
 * the dashboard, checkout) open in a Custom Tab, never a web view; coming back proves nothing, so the state is read again.
 */

/** Stripe's hosted pages in a Custom Tab (the system's in-app browser tab); the browser when there is none. */
fun openCustomTab(context: Context, url: String) {
    val uri = Uri.parse(url)
    runCatching { CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, uri) }.onFailure { openInBrowser(context, uri) }
}

/** Counts each return to the screen (not the first showing), to read a state again after a Custom Tab closes. */
@Composable
private fun rememberResumes(): Int {
    var resumes by remember { mutableIntStateOf(0) }
    var first by remember { mutableStateOf(true) }
    LifecycleResumeEffect(Unit) {
        if (first) first = false else resumes++
        onPauseOrDispose { }
    }
    return resumes
}

/** A value on the right of a row, in the type's own size. */
@Composable
private fun Amount(text: String, accent: Boolean = false, muted: Boolean = false) {
    Text(text, color = if (accent) T1.accent else if (muted) T1.muted else T1.text, fontFamily = T1.mono, fontSize = 15.sp, maxLines = 1)
}

/** A dollar amount typed into a well: digits and one point. */
@Composable
private fun MoneyField(value: String, onChange: (String) -> Unit, placeholder: String = "0") {
    T1TextField(value, { t -> onChange(t.filter { it.isDigit() || it == '.' }.take(9)) }, placeholder = placeholder, keyboardType = KeyboardType.Decimal, trailing = "USD")
}

// ── Account → Payments ──

/** Account's Payments row (after Sharing): `NOT CONNECTED` / `FINISH SETTING UP` / `READY`. Nothing while the server
 *  has no payments yet. */
fun LazyListScope.paymentsAccountRow(account: PaymentsAccount?, onOpen: () -> Unit) {
    val a = account ?: return
    item(key = "payments") {
        ListRow("Payments", onClick = onOpen) { Label(a.state, color = if (a.ready) T1.accent else T1.muted) }
    }
}

/** Your Stripe connection for entry fees: the state large, Connect Stripe (or Finish setting up), the dashboard. */
@Composable
fun PaymentsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var account by remember { mutableStateOf<PaymentsAccount?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var missing by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    // Onboarding was opened: the next return asks Stripe (the return itself proves nothing).
    var started by remember { mutableStateOf(false) }
    val resumes = rememberResumes()

    LaunchedEffect(resumes) {
        try {
            account = if (started) Repo.connectStatus() else Repo.paymentsAccount()
            error = null
        } catch (e: Throwable) {
            e.rethrowIfCancelled()
            if (Fees.notSetUp(e)) missing = true else error = paymentsMessage(e)
        }
    }

    fun open(what: suspend () -> String, onboarding: Boolean) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                val url = what()
                if (onboarding) started = true
                openCustomTab(context, url)
                error = null
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = paymentsMessage(e)
            } finally {
                busy = false
            }
        }
    }

    val a = account
    T1Screen {
        Bar("Payments", onBack = onBack)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (missing) Notice(Fees.NOT_SET_UP)
            else if (a == null) { if (error == null) Notice("Loading…") }
            else {
                Column(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 36.dp), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(a.state.uppercase(), color = if (a.ready) T1.accent else T1.text, fontFamily = T1.mono, fontSize = 24.sp, letterSpacing = 4.sp, textAlign = TextAlign.Center)
                    Label("Stripe")
                }
                if (a.ready) {
                    ArrowRow("Open Stripe dashboard") { open({ Repo.connectDashboard() }, onboarding = false) }
                    Notice(Fees.GOES_TO_STRIPE)
                } else a.disabledReason?.takeIf { it.isNotBlank() }?.let { InfoRow("Stripe says", it.replace('_', ' ').replace('.', ' ')) }
            }
            error?.let { Notice(it, error = true) }
        }
        if (a != null && !a.ready && !missing) BigAction(if (a.connected) "Finish setting up" else "Connect Stripe", accent = true, busy = busy) {
            open({ Repo.connectStart() }, onboarding = true)
        }
    }
}

// ── the fee, in Setup → Details ──

/** Setup → Details → Entry fee (`NONE`, or `$25 · APP OR DOOR`), opening the fee. Nothing while the server has no fees. */
@Composable
fun EventFeeRow(eventId: String, money: EventMoney?, leagueName: String?, startOpen: Boolean = false, onChanged: suspend () -> Unit) {
    val m = money ?: return
    var open by remember { mutableStateOf(startOpen) }
    ListRow("Entry fee", onClick = { open = true }) {
        Label(Fees.feeLine(m.fee), color = T1.text)
        site.table1.events.library.IconGlyph(site.table1.events.library.T1Icon.Arrow)
    }
    if (open) FeePanel(eventId, m, leagueName, { open = false }, onChanged)
}

private val keeps = listOf("none" to "Nothing", "flat" to "An amount", "percent" to "A percent")

/** The fee: Amount, How players pay, Refunds, You keep, Added prize money, Prizes, Remove fee. Saved whole. */
@Composable
private fun FeePanel(eventId: String, money: EventMoney, leagueName: String?, onDismiss: () -> Unit, onChanged: suspend () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val start = money.fee
    var amount by remember { mutableStateOf(Fees.field(start?.amountCents ?: 0)) }
    var payMode by remember { mutableStateOf(start?.payMode ?: "door") }
    var refundHours by remember { mutableStateOf(if (start == null) 24 else start.refundHours) }
    var keepKind by remember { mutableStateOf(start?.hostKeep?.kind ?: "none") }
    var keepFlat by remember { mutableStateOf(Fees.field(start?.hostKeep?.takeIf { it.kind == "flat" }?.value ?: 0)) }
    var keepPercent by remember { mutableIntStateOf(start?.hostKeep?.takeIf { it.kind == "percent" }?.value ?: 10) }
    var added by remember { mutableStateOf(Fees.field(start?.addedCents ?: 0)) }
    var payout by remember { mutableStateOf(start?.payout ?: Fees.payoutPresets.getValue("winner")) }
    var custom by remember { mutableStateOf(start != null && Fees.preset(start.payout) == "custom") }
    var stripeReady by remember { mutableStateOf(money.organizer?.stripe?.ready ?: money.appReady) }
    var connecting by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmRemove by remember { mutableStateOf(false) }
    val resumes = rememberResumes()

    // Back from Stripe's onboarding: ask Stripe whether the account can take payments now.
    LaunchedEffect(resumes) {
        if (!connecting) return@LaunchedEffect
        runCatching { Repo.connectStatus() }.onSuccess { stripeReady = it.ready; if (it.ready) connecting = false }.onFailure { it.rethrowIfCancelled() }
    }

    val cents = if (amount.isBlank()) 0 else Fees.cents(amount)
    val keep = when (keepKind) {
        "flat" -> HostKeep("flat", Fees.cents(keepFlat) ?: 0)
        "percent" -> HostKeep("percent", keepPercent)
        else -> HostKeep()
    }
    val fee = EventFee(cents ?: -1, "usd", if (cents == 0) "door" else payMode, refundHours, keep, if (added.isBlank()) 0 else Fees.cents(added) ?: -1, payout,
        start?.leagueCutCents ?: 0)
    val needsStripe = fee.takesAppPayments && !stripeReady
    val problem = when {
        cents == null -> "Type the fee as dollars, like 25 or 7.50"
        fee.addedCents < 0 -> "Type the added money as dollars"
        else -> Fees.problem(fee)
    }

    fun run(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                block()
                onChanged()
                onDismiss()
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }

    T1Panel("Entry fee", onDismiss, action = { if (problem == null && !needsStripe && !busy) BarAction("Save") { run { Repo.setEventFee(eventId, fee) } } }) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            error?.let { Notice(it, error = true) }
            FormBlock("Amount") { MoneyField(amount, { amount = it }, placeholder = "0 for a free event with prizes") }
            if (cents != 0) {
                FormBlock("How players pay") {
                    T1Segmented(Fees.payModes.map { it.second }, Fees.payModes.indexOfFirst { it.first == payMode }) { payMode = Fees.payModes[it].first }
                }
                if (needsStripe) ListRow("Connect Stripe", if (connecting) "Finish in Stripe, then come back" else null, onClick = {
                    scope.launch {
                        runCatching { Repo.connectStart() }.onSuccess { connecting = true; openCustomTab(context, it) }
                            .onFailure { it.rethrowIfCancelled(); error = paymentsMessage(it) }
                    }
                }) { Label("Connect", color = T1.accent) }
                if (fee.takesAppPayments) FormBlock("Refunds") {
                    T1Segmented(Fees.refunds.map { it.second }, Fees.refunds.indexOfFirst { it.first == refundHours }, scroll = true) { refundHours = Fees.refunds[it].first }
                }
                FormBlock("You keep") {
                    T1Segmented(keeps.map { it.second }, keeps.indexOfFirst { it.first == keepKind }) { keepKind = keeps[it].first }
                    if (keepKind == "flat") MoneyField(keepFlat, { keepFlat = it })
                    if (keepKind == "percent") T1Stepper("Percent", keepPercent, 0..100, Modifier.fillMaxWidth(), step = 5) { keepPercent = it }
                }
            }
            FormBlock("Added prize money") { MoneyField(added, { added = it }) }
            FormBlock("Prizes") {
                val picked = if (custom) "custom" else Fees.preset(payout)
                T1Segmented(Fees.presetLabels.map { it.second }, Fees.presetLabels.indexOfFirst { it.first == picked }, scroll = true) { i ->
                    val key = Fees.presetLabels[i].first
                    custom = key == "custom"
                    Fees.payoutPresets[key]?.let { payout = it }
                }
                Text(Fees.payoutWords(payout), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, lineHeight = 19.sp)
            }
            if (custom) {
                payout.forEachIndexed { i, b ->
                    val floor = (payout.getOrNull(i - 1)?.through ?: 0) + 1
                    val ceiling = (payout.getOrNull(i + 1)?.through ?: 65) - 1
                    FormBlock(if (b.through == floor) Leagues.ordinal(b.through) else "${Leagues.ordinal(floor)} to ${Leagues.ordinal(b.through)}") {
                        T1Stepper("Through place", b.through, floor..ceiling, Modifier.fillMaxWidth()) { v ->
                            payout = payout.toMutableList().also { it[i] = b.copy(through = v) }
                        }
                        T1Stepper("Percent each", b.percent.toInt(), 0..100, Modifier.fillMaxWidth()) { v ->
                            payout = payout.toMutableList().also { it[i] = b.copy(percent = v.toDouble()) }
                        }
                    }
                }
                if (payout.size < 8) ListRow("Add a bracket", onClick = {
                    val last = payout.lastOrNull()
                    payout = payout + PayoutBracket(if (last == null) 1 else minOf(last.through * 2, 64), if (last == null) 100.0 else 0.0)
                }) { site.table1.events.library.IconGlyph(site.table1.events.library.T1Icon.Plus) }
                if (payout.isNotEmpty()) ListRow("Remove the last bracket", onClick = { payout = payout.dropLast(1) })
                InfoRow("Total", Fees.pct(Fees.payoutTotal(payout)))
            }
            if (fee.leagueCutCents > 0 && leagueName != null) Notice("${Fees.money(fee.leagueCutCents)} an entry goes to $leagueName")
            problem?.let { Notice(it, error = true) }
            if (start != null) ListRow("Remove fee", onClick = { confirmRemove = true }) { Label("Remove", color = T1.danger) }
        }
    }
    if (confirmRemove) T1AlertDialog("Remove the entry fee?", { confirmRemove = false },
        confirm = { BarAction("Remove") { confirmRemove = false; run { Repo.setEventFee(eventId, null) } } },
        dismiss = { BarAction("Keep") { confirmRemove = false } })
}

// ── the event page: the fee and the prize pool ──

/** The event page's Prize pool row (`$162`), opening the breakdown. Nothing for an event with no fee. */
@Composable
fun PrizePoolRow(money: EventMoney?, leagueName: String? = null) {
    val fee = money?.fee ?: return
    val pool = money.pool ?: return
    var open by remember { mutableStateOf(false) }
    ListRow("Prize pool", onClick = { open = true }) {
        Amount(Fees.money(pool.poolCents))
        site.table1.events.library.IconGlyph(site.table1.events.library.T1Icon.Arrow)
    }
    if (!open) return
    T1Panel("Prize pool", { open = false }) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Column(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(Fees.money(pool.poolCents), color = T1.accent, fontFamily = T1.mono, fontSize = 48.sp, letterSpacing = 4.sp)
                Label(Fees.feeLine(fee))
            }
            InfoRow("Entries", "${pool.entries} · ${Fees.money(pool.grossCents)}")
            if (pool.leagueCutCents > 0) InfoRow(leagueName?.let { "To $it" } ?: "To the league", "−${Fees.money(pool.leagueCutCents)}")
            if (pool.hostKeepCents > 0) InfoRow("To the host", "−${Fees.money(pool.hostKeepCents)}")
            if (pool.addedCents > 0) InfoRow("Added", "+${Fees.money(pool.addedCents)}")
            val places = Fees.places(fee.payout, pool.poolCents)
            if (places.isNotEmpty()) {
                Section("Prizes as it stands")
                places.forEach { (place, cents) -> InfoRow(place, Fees.money(cents)) }
            }
        }
    }
}

// ── paying ──

/**
 * A signed-up player's own payment on an event with a fee: Pay $25 (checkout in a Custom Tab), Finishing your
 * payment…, PAID with Refund and leave, REFUNDED. The payment counts when Stripe's webhook says so, so every return
 * to the app reads the state again, every 2 s for up to 20 s while it's pending. [onChanged] re-reads event_money.
 */
@Composable
fun PlayerPayBlock(eventId: String, eventName: String, money: EventMoney?, onChanged: suspend () -> Unit, onLeft: () -> Unit) {
    val fee = money?.fee ?: return
    val me = money.me ?: return
    if (fee.amountCents == 0) return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmRefund by remember { mutableStateOf(false) }
    // Checkout was opened: the next return counts as coming back from it.
    var awaiting by remember { mutableStateOf(false) }
    val resumes = rememberResumes()
    val price = Fees.money(fee.amountCents)

    // Back from Stripe's page: the return proves nothing, so the state is read again, and counted once it's in.
    var returned by remember { mutableStateOf(false) }
    LaunchedEffect(resumes) {
        if (resumes > 0 && awaiting) {
            onChanged()
            awaiting = false
            returned = true
        }
    }
    LaunchedEffect(returned, me.status) {
        if (!returned) return@LaunchedEffect
        Telemetry.capture("pay_returned", mapOf("status" to me.status))
        returned = false
    }
    LaunchedEffect(me.status) {
        if (me.status != "pending") return@LaunchedEffect
        // The webhook lands a moment after Stripe's page closes: every 2 s for up to 20 s.
        repeat(10) {
            delay(2000)
            onChanged()
        }
    }

    fun pay() {
        if (busy) return
        busy = true
        scope.launch {
            try {
                val url = Repo.checkout(eventId)
                awaiting = true
                error = null
                if (!EventDemo.shown) openCustomTab(context, url)
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = paymentsMessage(e)
            } finally {
                busy = false
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        when (me.status) {
            "paid" -> {
                ListRow("Entry fee", price.takeIf { me.method != "comp" }) { Label(Fees.paidWord(me.method), color = T1.accent) }
                if (me.canRefund) Row { Ghost("Refund and leave", enabled = !busy) { confirmRefund = true } }
            }
            "pending" -> {
                ListRow("Finishing your payment…", price)
                Row { Ghost("Pay again", enabled = !busy && me.canPay) { pay() } }
            }
            else -> {
                if (me.status == "refunded") ListRow("Entry fee", price) { Label("Refunded") }
                if (me.canPay) {
                    BigAction(if (me.status == "refunded") "Pay again" else "Pay $price", accent = true, busy = busy) { pay() }
                    if (fee.payMode == "either") Box(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 10.dp), contentAlignment = Alignment.Center) {
                        Label("or pay at the door")
                    }
                } else if (me.status != "refunded") ListRow("$price at the door") { Label("Unpaid") }
            }
        }
        error?.let { Notice(it, error = true) }
    }
    if (confirmRefund) T1AlertDialog("Refund and leave $eventName?", { confirmRefund = false },
        body = { Text("$price goes back to how you paid, and your seat opens.", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp) },
        confirm = {
            BarAction("Refund and leave") {
                confirmRefund = false
                busy = true
                scope.launch {
                    try {
                        Repo.refund(eventId)
                        Repo.leaveEvent(eventId, waitlist = false)
                        onLeft()
                    } catch (e: Throwable) {
                        e.rethrowIfCancelled()
                        error = paymentsMessage(e)
                        onChanged()
                    } finally {
                        busy = false
                    }
                }
            }
        },
        dismiss = { BarAction("Stay") { confirmRefund = false } })
}

// ── the organizer's Players lists ──

/** `4 UNPAID` for the Players header; null with no fee or everyone paid. */
fun unpaidHeader(money: EventMoney?): String? = money?.takeIf { it.fee != null && (it.fee.amountCents > 0) }?.organizer?.unpaid?.takeIf { it > 0 }?.let { "$it unpaid" }

/**
 * A player's payment tag in the organizer's lists (`PAID · APP`, `UNPAID`, …), opening Paid at the door, Comp, Unpaid,
 * and Refund for a payment made in the app. Nothing for an event with no fee.
 */
@Composable
fun PayTag(eventId: String, money: EventMoney?, participantId: String, name: String, enabled: Boolean = true, onChanged: suspend () -> Unit, onError: (String?) -> Unit) {
    val fee = money?.fee?.takeIf { it.amountCents > 0 } ?: return
    val p: PlayerPayment = money.payment(participantId) ?: return
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var confirmRefund by remember { mutableStateOf(false) }
    val tag = Fees.payTag(p.status, p.method)
    val byApp = p.status == "paid" && p.method == "app"

    fun run(block: suspend () -> Unit) {
        scope.launch {
            try {
                block()
                onError(null)
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                onError(paymentsMessage(e))
            }
            onChanged()
        }
    }

    // Sits at the head of the row's quiet line; the tap target reaches a little past the type.
    Label(tag, Modifier.clickable(enabled = enabled, onClickLabel = "Payment") { menu = true }.padding(top = 5.dp, bottom = 5.dp, end = 8.dp).semantics { contentDescription = "$name: $tag" },
        color = if (p.status == "paid") T1.accent else if (p.status == "unpaid") T1.text else T1.muted)
    if (menu) T1Menu("$name · ${Fees.money(fee.amountCents)}", buildList {
        if (byApp) add(T1MenuItem("Refund", danger = true) { confirmRefund = true })
        else {
            add(T1MenuItem("Paid at the door", selected = p.status == "paid" && p.method == "door") { run { Repo.markPayment(eventId, participantId, "door") } })
            add(T1MenuItem("Comp", selected = p.method == "comp" && p.status == "paid") { run { Repo.markPayment(eventId, participantId, "comp") } })
            add(T1MenuItem("Unpaid", selected = p.status == "unpaid") { run { Repo.markPayment(eventId, participantId, "unpaid") } })
        }
    }) { menu = false }
    if (confirmRefund) T1AlertDialog("Refund $name?", { confirmRefund = false },
        body = { Text("${Fees.money(p.amountCents)} goes back to how they paid, from your Stripe balance. They stay in the event as unpaid.", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp) },
        confirm = { BarAction("Refund") { confirmRefund = false; run { Repo.refund(eventId, participantId) } } },
        dismiss = { BarAction("Keep") { confirmRefund = false } })
}

// ── Results → Prizes ──

/** The pool, then each place with its amount and `PAID · CASH` or a Mark paid menu; Split edits the amounts against
 *  the pool; Back to the table drops an agreed split. */
@Composable
fun PrizesTab(eventId: String, money: EventMoney?, onChanged: suspend () -> Unit) {
    val scope = rememberCoroutineScope()
    val pool = money?.pool
    val prizes = money?.prizes.orEmpty()
    var splitting by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var menuFor by remember { mutableStateOf<Prize?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun run(done: () -> Unit = {}, block: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                block()
                error = null
                done()
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = userMessage(e)
            } finally {
                busy = false
            }
            onChanged()
        }
    }

    if (money?.fee == null || pool == null) {
        Column { Notice("No entry fee, so no prizes to hand out.") }
        return
    }
    val total = if (splitting) prizes.sumOf { Fees.cents(draft[it.participantId].orEmpty()) ?: 0 } else prizes.sumOf { it.amountCents }
    val over = total > pool.poolCents
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        item(key = "pool") {
            Column(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(Fees.money(pool.poolCents), color = T1.accent, fontFamily = T1.mono, fontSize = 48.sp, letterSpacing = 4.sp)
                Label(if (splitting) "${Fees.money(total)} of ${Fees.money(pool.poolCents)}" else "Prize pool", color = if (over) T1.danger else T1.muted)
            }
        }
        error?.let { e -> item(key = "error") { Notice(e, error = true) } }
        if (prizes.isEmpty()) item(key = "none") { ListRow(if (pool.poolCents == 0) "Nothing in the pool" else "No prizes set") }
        items(prizes, key = { it.participantId }) { p ->
            Row(Modifier.fillMaxWidth().background(T1.surface).let { m -> if (!splitting) m.clickable(onClickLabel = "Mark paid") { menuFor = p } else m }
                .padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(Leagues.ordinal(p.place).uppercase(), Modifier.width(40.dp), color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp, maxLines = 1)
                Text(p.name, Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (splitting) {
                    Box(Modifier.width(130.dp)) { MoneyField(draft[p.participantId].orEmpty(), { v -> draft = draft + (p.participantId to v) }) }
                } else {
                    Label(if (p.paid) Fees.prizePaidTag(p.paidHow) else "Mark paid", color = if (p.paid) T1.accent else T1.text)
                    Text(Fees.money(p.amountCents), color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, textAlign = TextAlign.End)
                }
            }
        }
        if (prizes.isNotEmpty()) item(key = "actions") {
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                if (splitting) {
                    Ghost("Cancel", enabled = !busy) { splitting = false }
                    Ghost(if (over) "Over the pool" else "Save split", enabled = !busy && !over, accent = !over) {
                        val rows = prizes.map { it.participantId to (Fees.cents(draft[it.participantId].orEmpty()) ?: 0) }
                        run({ splitting = false }) { Repo.setPrizes(eventId, rows) }
                    }
                } else {
                    Ghost("Split", enabled = !busy) {
                        draft = prizes.associate { it.participantId to Fees.field(it.amountCents).ifEmpty { "0" } }
                        splitting = true
                    }
                    if (prizes.any { it.custom }) Ghost("Back to the table", enabled = !busy) { run { Repo.setPrizes(eventId, null) } }
                }
            }
        }
    }
    menuFor?.let { p ->
        T1Menu("${p.name} · ${Fees.money(p.amountCents)}", Fees.paidHows.map { (how, label) ->
            T1MenuItem(label, selected = p.paid && p.paidHow == how) { run { Repo.markPrize(eventId, p.participantId, true, how) } }
        } + listOfNotNull(if (p.paid) T1MenuItem("Not paid yet") { run { Repo.markPrize(eventId, p.participantId, false, null) } } else null)) { menuFor = null }
    }
}

// ── a league's cut ──

/** A season's money, read once per season (and again on [reloads]); null until it's read or while the server has none. */
@Composable
fun rememberLeagueMoney(seasonId: String?, reloads: Int = 0): LeagueMoney? {
    var money by remember(seasonId) { mutableStateOf<LeagueMoney?>(null) }
    LaunchedEffect(seasonId, reloads) {
        val id = seasonId ?: return@LaunchedEffect
        runCatching { Repo.leagueMoney(id) }.onSuccess { money = it }.onFailure { it.rethrowIfCancelled() }
    }
    return money
}

/** The league page's `Prize pool $1,400` under the season, when the cut is over 0. */
@Composable
fun LeaguePoolRow(money: LeagueMoney?) {
    val m = money?.takeIf { it.entryCutCents > 0 } ?: return
    ListRow("Prize pool", "${Fees.money(m.entryCutCents)} AN ENTRY") { Amount(Fees.money(m.poolCents)) }
}

/** The season editor's Cut per entry (0 = none). */
@Composable
fun CutPerEntryField(value: String, onChange: (String) -> Unit) {
    FormBlock("Cut per entry") { MoneyField(value, onChange, placeholder = "0") }
}

/** A league's tools → Dues: each event's entries, what it owes and what was received, with Mark received. */
@Composable
fun LeagueDuesScreen(league: String, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var seasonId by remember { mutableStateOf<String?>(null) }
    var title by remember { mutableStateOf("Dues") }
    var reloads by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }
    var menuFor by remember { mutableStateOf<LeagueMoney.Due?>(null) }
    var typing by remember { mutableStateOf<Pair<LeagueMoney.Due, String>?>(null) }
    LaunchedEffect(league) {
        runCatching { LeagueCache.of(league) ?: Repo.leagueView(league) }.onSuccess { p -> seasonId = p.season?.id; p.season?.name?.let { title = "Dues · $it" } }
            .onFailure { it.rethrowIfCancelled(); error = userMessage(it) }
    }
    val money = rememberLeagueMoney(seasonId, reloads)

    fun mark(d: LeagueMoney.Due, cents: Int) {
        scope.launch {
            runCatching { Repo.markLeagueDue(d.eventId, cents) }.onSuccess { error = null }.onFailure { it.rethrowIfCancelled(); error = userMessage(it) }
            reloads++
        }
    }

    T1Screen {
        Bar(title, onBack = onBack)
        error?.let { Notice(it, error = true) }
        val m = money
        if (m == null) {
            if (error == null) Notice("Loading…")
            return@T1Screen
        }
        val events = m.events.orEmpty()
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item(key = "head") {
                Column(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(Fees.money(m.poolCents), color = T1.accent, fontFamily = T1.mono, fontSize = 48.sp, letterSpacing = 4.sp)
                    Label("${Fees.money(m.receivedCents ?: 0)} received · ${Fees.money(m.entryCutCents)} an entry")
                }
            }
            if (events.isEmpty()) item(key = "none") { ListRow("No paid entries yet") }
            items(events, key = { it.eventId }) { d ->
                val settled = d.receivedCents >= d.owedCents && d.owedCents > 0
                ListRow(d.name, "${d.entries} ${if (d.entries == 1) "ENTRY" else "ENTRIES"} · OWES ${Fees.money(d.owedCents)}", onClick = { menuFor = d }) {
                    Label(if (d.receivedCents > 0) "${Fees.money(d.receivedCents)} received" else "Mark received", color = if (settled) T1.accent else T1.text)
                }
            }
        }
    }
    menuFor?.let { d ->
        T1Menu(d.name, listOfNotNull(
            T1MenuItem("Received ${Fees.money(d.owedCents)}", selected = d.receivedCents == d.owedCents && d.owedCents > 0) { mark(d, d.owedCents) },
            T1MenuItem("Another amount…") { typing = d to Fees.field(d.receivedCents) },
            if (d.receivedCents > 0) T1MenuItem("Nothing received") { mark(d, 0) } else null,
        )) { menuFor = null }
    }
    typing?.let { (d, text) ->
        T1AlertDialog("Received from ${d.name}", { typing = null },
            body = { MoneyField(text, { typing = d to it }) },
            confirm = { BarAction("Save") { Fees.cents(text)?.let { mark(d, it) }; typing = null } },
            dismiss = { BarAction("Cancel") { typing = null } })
    }
}
