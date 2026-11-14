import SwiftUI
import AuthenticationServices
import Supabase

// Entry fees and prizes (contract/entry-fees-2026-11-13.md): Account → Payments, the fee editor of Setup → Details,
// the event page's fee and Prize pool, a player's Pay / pending / paid / refund states, the organizer's payment tags
// and Results → Prizes, and a league's Prize pool, Cut per entry and Dues. Everything here draws nothing until the
// server answers, and nothing at all on a server without it.

// MARK: Stripe's pages

/// Stripe's onboarding and checkout open in the system's in-app browser tab (never a web view of ours). It closes on
/// Done, or when Stripe's return page hands back to the app (`table1://…`). The return proves nothing: callers re-read
/// the state afterwards.
@MainActor
final class PayBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PayBrowser()
    private var session: ASWebAuthenticationSession?

    private final class Once: @unchecked Sendable { var done = false }

    func open(_ url: URL) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = Once()
            let finish: @Sendable () -> Void = {
                DispatchQueue.main.async {
                    if !once.done { once.done = true; done.resume() }
                }
            }
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "table1") { _, _ in finish() }
            s.presentationContextProvider = self
            session = s
            if !s.start() { finish() }
        }
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

// MARK: Account → Payments

/// The Account row after Sharing: `NOT CONNECTED` / `FINISH SETTING UP` / `READY`. Hidden until the server answers
/// and says payments are open to this account (`PaymentsGate`, refreshed by AccountSocialRows).
struct PaymentsRow: View {
    var body: some View {
        let gate = PaymentsGate.shared
        Group {
            if gate.enabled, let account = gate.account {
                Button {
                    T1Overlays.shared.present(full: true) {
                        PaymentsPanel(account: account) { gate.connected($0) }.screen("payments")
                    }
                } label: {
                    ListRow(title: "Payments") { LabelText(account.state, color: account.ready ? T1.accent : T1.muted) }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Your Stripe account: its state, large; Connect Stripe or Finish setting up; once ready, the dashboard.
struct PaymentsPanel: View {
    @State var account: PaymentsAccount
    var changed: (PaymentsAccount) -> Void = { _ in }
    @State private var busy = false
    @State private var error: String?
    @State private var off = ToolsServer.paymentsOff

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Payments", back: { T1Overlays.shared.dismissPanel() })
            ScrollView {
                VStack(spacing: 1) {
                    VStack(alignment: .leading, spacing: 8) {
                        LabelText("Stripe")
                        Text(account.state.uppercased()).font(T1.mono(24)).tracking(2)
                            .foregroundStyle(account.ready ? T1.accent : T1.text)
                        if account.ready { LabelText(account.payouts == true ? "Payouts on" : "Payouts not on yet") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20).background(T1.surface)
                    if let off { Notice(off) }
                    if let error { Notice(error, error: true) }
                    if account.ready {
                        Notice("Entry fees go straight to your Stripe account.")
                        Ghost(text: busy ? "Working…" : "Open Stripe dashboard") { open { try await Repo.connectDashboard() } }
                    }
                }
            }
            if !account.ready, off == nil {
                BigAction(text: account.connected ? "Finish setting up" : "Connect Stripe", busy: busy, accent: true) {
                    open { try await Repo.connectStart() }
                }
            }
        }
        .foregroundStyle(T1.text)
        .task { await status() }
        // Coming back to the app (from Stripe in a browser, say) asks Stripe again.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in Task { await status() } }
    }

    /// Opens one of Stripe's pages, then asks Stripe where the account stands.
    private func open(_ link: @escaping () async throws -> URL) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                await PayBrowser.shared.open(try await link())
                await status()
            } catch let e as ToolsServer.PaymentsOff {
                off = e.message
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func status() async {
        do {
            account = try await Repo.connectStatus()
            off = nil
            changed(account)
        } catch let e as ToolsServer.PaymentsOff {
            off = e.message
        } catch {}
    }
}

// MARK: Setup → Details → Entry fee

/// `Entry fee · $25 · APP OR DOOR`, opening the fee. Hidden on a server without fees.
struct EntryFeeRow: View {
    let eventId: String

    var body: some View {
        let side = EventSide.of(eventId), gate = PaymentsGate.shared
        Group {
            LoadOnce {
                await gate.load()
                if gate.enabled, side.money == nil { await side.refreshMoney() }
            }
            if gate.enabled, let money = side.money {
                Section1("Entry fee")
                Button {
                    T1Overlays.shared.present(full: true) { FeeEditor(eventId: eventId, money: money).screen("event_fee") }
                } label: {
                    ListRow(title: money.fee == nil ? "None" : Money.feeLine(money.fee), detail: money.fee.map { Money.payoutWords($0.payout ?? []) }) {
                        LabelText(money.fee == nil ? "Add" : "Change", color: T1.text)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The fee: the amount, how players pay, refunds, what the host keeps, added prize money and the prize brackets.
struct FeeEditor: View {
    let eventId: String
    let had: Bool
    let paid: Bool
    let leagueCut: Int
    @State private var amount: String
    @State private var payMode: String
    @State private var refundHours: Int?
    @State private var keepKind: String
    @State private var keepValue: String
    @State private var added: String
    @State private var preset: String
    @State private var custom: [PayoutBracket]
    @State private var stripeReady: Bool
    @State private var league: String?
    @State private var busy = false
    @State private var error: String?

    init(eventId: String, money: EventMoney) {
        self.eventId = eventId
        let f = money.fee
        had = f != nil
        paid = (money.pool?.entries ?? 0) > 0
        leagueCut = f?.leagueCutCents ?? 0
        _amount = State(initialValue: f.map { Money.typed($0.amountCents) } ?? "")
        _payMode = State(initialValue: f?.payMode ?? "door")
        _refundHours = State(initialValue: f?.refundHours)
        _keepKind = State(initialValue: f?.hostKeep?.kind ?? "none")
        let keep = f?.hostKeep ?? HostKeep()
        _keepValue = State(initialValue: keep.kind == "flat" ? Money.typed(Int(keep.value)) : keep.kind == "percent" ? String(format: "%g", keep.value) : "")
        _added = State(initialValue: (f?.addedCents ?? 0) > 0 ? Money.typed(f?.addedCents ?? 0) : "")
        let payout = f?.payout ?? Money.payoutPresets[0].payout
        _preset = State(initialValue: Money.preset(payout))
        _custom = State(initialValue: payout)
        _stripeReady = State(initialValue: money.organizer?.stripe?.ready ?? false)
    }

    private var amountCents: Int? { Money.cents(amount) }
    private var addedCents: Int? { Money.cents(added) }
    private var payout: [PayoutBracket] { Money.payoutPresets.first { $0.key == preset }?.payout ?? custom }
    private var keep: Int? { keepKind == "none" ? 0 : keepKind == "flat" ? Money.cents(keepValue) : Int(keepValue.trimmingCharacters(in: .whitespaces)) }
    private var needsStripe: Bool { payMode != "door" && !stripeReady && (amountCents ?? 0) > 0 }

    private var problem: String? {
        guard let a = amountCents, a == 0 || (50...100_000).contains(a) else { return "An entry fee is $0.50 to $1,000, or 0 for a free event with prizes." }
        guard let k = keep, k >= 0, keepKind != "percent" || k <= 100 else { return "You keep nothing, an amount, or a percent up to 100." }
        guard let more = addedCents, (0...10_000_000).contains(more) else { return "Added prize money is $0 to $100,000." }
        if !Money.payoutValid(payout) { return "Brackets go up, and prizes can't pass 100% of the pool." }
        return nil
    }

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Entry fee", back: { T1Overlays.shared.dismissPanel() })
            ScrollView {
                VStack(spacing: 1) {
                    MoneyField(label: "Amount · USD", text: $amount).disabled(paid)
                    if paid { Notice("Entries are paid: the amount is locked.") }

                    Section1("How players pay")
                    T1Segmented(options: Money.payModes.map { (value: $0.key, label: $0.label) }, selection: $payMode)
                    if needsStripe {
                        ListRow(title: "Connect Stripe", detail: "Before taking payments in the app") {
                            BarButton(busy ? "…" : "Connect") { connect() }
                        }
                    }

                    pick("Refunds", Money.refunds.first { $0.hours == refundHours }?.label ?? "Ask me") {
                        Money.refunds.map { r in T1MenuItem(title: r.label, checked: r.hours == refundHours) { refundHours = r.hours } }
                    }
                    pick("You keep", keepKind == "flat" ? "An amount" : keepKind == "percent" ? "A percent" : "Nothing") {
                        [("none", "Nothing"), ("flat", "An amount"), ("percent", "A percent")].map { k in
                            T1MenuItem(title: k.1, checked: keepKind == k.0) { keepKind = k.0; keepValue = "" }
                        }
                    }
                    if keepKind == "flat" { MoneyField(label: "You keep · USD", text: $keepValue) }
                    if keepKind == "percent" { MoneyField(label: "You keep · % after the league", text: $keepValue) }
                    MoneyField(label: "Added prize money · USD", text: $added)

                    Section1("Prizes")
                    pick(Money.payoutPresets.first { $0.key == preset }?.label ?? "Custom brackets", "Change") {
                        Money.payoutPresets.map { p in T1MenuItem(title: p.label, checked: preset == p.key) { preset = p.key; custom = p.payout } }
                            + [T1MenuItem(title: "Custom brackets", checked: preset == "custom") { preset = "custom" }]
                    }
                    if preset == "custom" { brackets }
                    InfoRow(label: "Pays", value: Money.payoutWords(payout).replacingOccurrences(of: " · ", with: "\n"))
                    if leagueCut > 0 {
                        InfoRow(label: league ?? "League", value: "\(Money.text(leagueCut)) an entry")
                    }

                    if let error { Notice(error, error: true) }
                    if had {
                        Color.clear.frame(height: 15)
                        Button { remove() } label: {
                            LabelText("Remove fee", color: T1.danger).frame(maxWidth: .infinity).padding(.vertical, 14).background(T1.surface)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let problem, !amount.isEmpty { Notice(problem, error: true) }
            BigAction(text: "Save", enabled: problem == nil && !amount.trimmingCharacters(in: .whitespaces).isEmpty && !needsStripe, busy: busy, accent: true) { save() }
        }
        .foregroundStyle(T1.text)
        .task { league = (try? await Repo.eventAbout(eventId))?.league?.name }
    }

    private func pick(_ title: String, _ value: String, _ items: @escaping () -> [T1MenuItem]) -> some View {
        Button { T1Overlays.shared.showMenu(title, items()) } label: {
            ListRow(title: title) {
                HStack(spacing: 4) {
                    LabelText(value, color: T1.text)
                    T1Icon.arrowDropDown.fill(T1.text).frame(width: 18, height: 18)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Custom brackets: the place each reaches through and its percent of the pool.
    @ViewBuilder private var brackets: some View {
        ForEach(custom.indices, id: \.self) { i in
            HStack(spacing: 1) {
                T1Stepper(label: "Through", value: $custom[i].through, range: 1...64)
                Button { custom.remove(at: i) } label: {
                    LabelText("Remove", color: T1.danger).padding(.horizontal, 12).frame(maxHeight: .infinity).background(T1.surface)
                }
                .buttonStyle(.plain)
            }
            .fixedSize(horizontal: false, vertical: true)
            T1Stepper(label: "Percent each", value: Binding(get: { Int(custom[i].percent.rounded()) }, set: { custom[i].percent = Double($0) }),
                      range: 0...100, unit: "%")
        }
        if custom.count < 8 {
            Ghost(text: "Add a bracket") {
                let last = custom.last
                custom.append(PayoutBracket(through: min(64, max(1, (last?.through ?? 0) * 2)), percent: 0))
            }
        }
        InfoRow(label: "Total", value: Money.percentText(Money.payoutTotal(custom)))
    }

    private func connect() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                await PayBrowser.shared.open(try await Repo.connectStart())
                stripeReady = (try? await Repo.connectStatus())?.ready ?? false
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let a = amountCents, let k = keep, let more = addedCents else { return }
        busy = true
        error = nil
        var fee: [String: AnyJSON] = [
            "pay_mode": .string(a == 0 ? "door" : payMode), "refund_hours": refundHours.map { .integer($0) } ?? .null,
            "host_keep": .object(["kind": .string(keepKind), "value": .integer(k)]), "added_cents": .integer(more),
            "payout": .array(payout.map { .object(["through": .integer($0.through), "percent": .double($0.percent)]) }),
        ]
        if !paid { fee["amount_cents"] = .integer(a) }
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Repo.setEventFee(eventId, fee: fee)
                await EventSide.of(eventId).refreshMoney()
                T1Overlays.shared.dismissPanel()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func remove() {
        T1Overlays.shared.ask("Remove the entry fee?", message: "The event becomes free to enter, with no prize pool.", action: "Remove fee", destructive: true) {
            Task { @MainActor in
                do {
                    try await Repo.setEventFee(eventId, fee: nil)
                    await EventSide.of(eventId).refreshMoney()
                    T1Overlays.shared.dismissPanel()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

/// A box for an amount: decimal pad, the label saying its unit.
struct MoneyField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabelText(label)
            TextField("", text: $text, prompt: Text("0").foregroundStyle(T1.disabled))
                .font(T1.mono(20)).tint(T1.accent).keyboardType(.decimalPad)
                .onChange(of: text) { _, v in if v.count > 9 { text = String(v.prefix(9)) } }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T1.surface)
        .focusArea()
    }
}

// MARK: the event page: the fee and the pool

/// `Prize pool · $25 · APP OR DOOR … $162`, opening the breakdown. Nothing for an event without a fee.
struct PrizePoolRow: View {
    let eventId: String

    var body: some View {
        if let money = EventSide.of(eventId).money, let fee = money.fee, let pool = money.pool {
            Button {
                T1Overlays.shared.present(full: true) { PrizePoolPanel(fee: fee, pool: pool).screen("prize_pool") }
            } label: {
                ListRow(title: "Prize pool", detail: Money.feeLine(fee)) {
                    HStack(spacing: 8) {
                        Text(Money.text(pool.poolCents)).font(T1.mono(16)).monospacedDigit()
                        T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// The pool as it stands: entries, to the league, to the host, added, the pool, then each place's prize at it.
struct PrizePoolPanel: View {
    let fee: EventFee
    let pool: MoneyPool

    private var places: [(label: String, cents: Int)] {
        var out: [(String, Int)] = []
        var last = 0
        for b in fee.payout ?? [] {
            let label = b.through == last + 1 ? Leagues.ordinal(b.through) : "\(Leagues.ordinal(last + 1)) to \(Leagues.ordinal(b.through))"
            out.append((label, Money.prizeAt(fee.payout ?? [], poolCents: pool.poolCents, place: b.through)))
            last = b.through
        }
        return out
    }

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Prize pool", back: { T1Overlays.shared.dismissPanel() })
            ScrollView {
                VStack(spacing: 1) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabelText("Pool")
                        Text(Money.text(pool.poolCents)).font(T1.mono(44)).monospacedDigit().foregroundStyle(T1.accent)
                        LabelText(Money.feeLine(fee))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20).background(T1.surface)
                    InfoRow(label: "Entries · \(pool.entries)", value: Money.text(pool.grossCents))
                    if pool.leagueCutCents > 0 { InfoRow(label: "To the league", value: "−" + Money.text(pool.leagueCutCents)) }
                    if pool.hostKeepCents > 0 { InfoRow(label: "To the host", value: "−" + Money.text(pool.hostKeepCents)) }
                    if pool.addedCents > 0 { InfoRow(label: "Added", value: "+" + Money.text(pool.addedCents)) }
                    if !places.isEmpty {
                        Section1("Prizes at this pool")
                        ForEach(places, id: \.label) { p in InfoRow(label: p.label, value: Money.text(p.cents)) }
                    }
                }
            }
        }
        .foregroundStyle(T1.text)
    }
}

// MARK: paying (a player who is signed up)

/// Your entry: Pay $25, Finishing your payment…, PAID (with Refund and leave), REFUNDED. Nothing when you aren't in the
/// event or it has no fee.
struct PayRows: View {
    let eventId: String
    /// After Refund and leave.
    var left: () -> Void = {}
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let side = EventSide.of(eventId)
        if let fee = side.money?.fee, let me = side.money?.me, fee.amountCents > 0 {
            let price = Money.text(fee.amountCents)
            if let error { Notice(error, error: true) }
            if let off = ToolsServer.paymentsOff, fee.takesApp, me.status != "paid" { Notice(off) }
            switch me.status {
            case "paid":
                ListRow(title: "Entry", detail: price) { LabelText(Money.paidText(method: me.method), color: T1.accent) }
                if me.canRefund == true { Ghost(text: busy ? "Working…" : "Refund and leave") { askRefund(price) } }
            case "pending":
                ListRow(title: "Finishing your payment…", detail: price) { BarButton(busy ? "…" : "Pay again") { pay() } }
            case "refunded":
                ListRow(title: "Entry", detail: price) {
                    HStack(spacing: 16) {
                        LabelText("Refunded")
                        if me.canPay == true { BarButton(busy ? "…" : "Pay again") { pay() } }
                    }
                }
            default:
                if me.canPay == true {
                    BigAction(text: "Pay \(price)", busy: busy, accent: true) { pay() }
                    if fee.payMode == "either" {
                        LabelText("or pay at the door").frame(maxWidth: .infinity).padding(.vertical, 10).background(T1.surface)
                    }
                } else {
                    ListRow(title: "\(price) at the door") { LabelText("Unpaid") }
                }
            }
        }
    }

    /// Stripe's checkout in the browser tab; whatever it says on the way back, the state is read again (the webhook
    /// settles it), every 2 s for up to 20 s while it's pending.
    private func pay() {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                await PayBrowser.shared.open(try await Repo.checkout(eventId))
                let side = EventSide.of(eventId)
                await side.refreshMoney()
                Telemetry.capture("pay_returned", ["status": side.money?.me?.status ?? "unknown"])
                await side.settle()
            } catch let e as ToolsServer.PaymentsOff {
                error = e.message
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func askRefund(_ price: String) {
        T1Overlays.shared.ask("Refund and leave?", message: "Your \(price) goes back to your card and you leave the event.", action: "Refund and leave", destructive: true) {
            busy = true
            Task { @MainActor in
                defer { busy = false }
                do {
                    try await Repo.refund(eventId)
                    try await Repo.leaveEvent(eventId, waitlist: false)
                    await EventSide.of(eventId).refreshMoney()
                    left()
                } catch {
                    self.error = error.localizedDescription
                    await EventSide.of(eventId).refreshMoney()
                }
            }
        }
    }
}

// MARK: the organizer's side

/// A player's payment tag in the organizer's Players lists; a tap opens Paid at the door / Comp / Unpaid / Refund.
struct PayTagButton: View {
    let eventId: String
    let participantId: String
    let name: String
    var failed: (String) -> Void = { _ in }

    var body: some View {
        let side = EventSide.of(eventId)
        if side.money?.fee != nil, let pay = side.money?.payment(participantId) {
            Button { menu(pay) } label: { LabelText(pay.tag, color: pay.status == "unpaid" ? T1.text : T1.muted) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name), \(pay.tag)")
        }
    }

    private func menu(_ pay: PlayerPayment) {
        let app = pay.status == "paid" && pay.method == "app"
        var items: [T1MenuItem] = []
        if app {
            // Payments made in the app change only by a refund.
            items.append(T1MenuItem(title: "Refund", detail: pay.amountCents.map(Money.text), destructive: true) {
                T1Overlays.shared.ask("Refund \(name)?", message: "Their entry goes back to their card. They stay in the event, unpaid.", action: "Refund", destructive: true) {
                    run { try await Repo.refund(eventId, participantId: participantId) }
                }
            })
        } else {
            items = [
                T1MenuItem(title: "Paid at the door", checked: pay.status == "paid" && pay.method == "door") { mark("door") },
                T1MenuItem(title: "Comp", checked: pay.method == "comp" && pay.status == "paid") { mark("comp") },
                T1MenuItem(title: "Unpaid", checked: pay.status == "unpaid") { mark("unpaid") },
            ]
        }
        T1Overlays.shared.showMenu(name, message: pay.tag, items)
    }

    private func mark(_ state: String) { run { try await Repo.markPayment(eventId, participantId: participantId, state: state) } }

    private func run(_ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await work() } catch { failed(error.localizedDescription) }
            await EventSide.of(eventId).refreshMoney()
        }
    }
}

extension EventSide {
    /// Players who haven't paid (0 with no fee, or for anyone who doesn't run the event).
    var unpaid: Int { money?.fee == nil ? 0 : money?.organizer?.unpaid ?? 0 }
    /// ` · 4 UNPAID` for the Players header.
    var unpaidSuffix: String { unpaid > 0 ? " · \(unpaid) unpaid" : "" }
}

/// Results → Prizes: the pool, each place with its amount and `PAID · CASH` or Mark paid; Split; Back to the table.
struct PrizesTab: View {
    let eventId: String
    @State private var error: String?

    var body: some View {
        let side = EventSide.of(eventId)
        HairlineList {
            if let money = side.money, let pool = money.pool {
                let prizes = money.prizes ?? []
                VStack(alignment: .leading, spacing: 6) {
                    LabelText("Prize pool")
                    Text(Money.text(pool.poolCents)).font(T1.mono(44)).monospacedDigit().foregroundStyle(T1.accent)
                    LabelText("\(pool.entries) paid \(pool.entries == 1 ? "entry" : "entries")")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20).background(T1.surface)
                if let error { Notice(error, error: true) }
                if prizes.isEmpty { ListRow(title: "No prizes yet") }
                ForEach(prizes) { p in
                    Button { menu(p) } label: {
                        ListRow(title: p.name, detail: Leagues.ordinal(p.place).uppercased() + (p.custom == true ? " · SPLIT" : "")) {
                            HStack(spacing: 12) {
                                Text(Money.text(p.amountCents)).font(T1.mono(16)).monospacedDigit()
                                LabelText(p.paid == true ? Money.prizeTag(paidHow: p.paidHow) : "Mark paid", color: p.paid == true ? T1.accent : T1.text)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !prizes.isEmpty {
                    HStack(spacing: 1) {
                        Ghost(text: "Split") {
                            T1Overlays.shared.present(full: true) { PrizeSplitPanel(eventId: eventId, prizes: prizes, poolCents: pool.poolCents).screen("prize_split") }
                        }
                        if prizes.contains(where: { $0.custom == true }) {
                            Ghost(text: "Back to the table") { run { try await Repo.setPrizes(eventId, rows: nil) } }
                        }
                    }
                }
            }
        }
        .task { await side.refreshMoney() }
    }

    private func menu(_ p: Prize) {
        let items = p.paid == true
            ? [T1MenuItem(title: "Not paid") { run { try await Repo.markPrize(eventId, participantId: p.participantId, paid: false, how: nil) } }]
            : Money.paidHows.map { how in
                T1MenuItem(title: how.label) { run { try await Repo.markPrize(eventId, participantId: p.participantId, paid: true, how: how.key) } }
            }
        T1Overlays.shared.showMenu(p.name, message: "\(Money.text(p.amountCents)) · \(Leagues.ordinal(p.place))", items)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await work(); error = nil } catch { self.error = error.localizedDescription }
            await EventSide.of(eventId).refreshMoney()
        }
    }
}

/// An agreed split: every prize's amount, with the running total against the pool.
struct PrizeSplitPanel: View {
    let eventId: String
    let prizes: [Prize]
    let poolCents: Int
    @State private var amounts: [String: String] = [:]
    @State private var busy = false
    @State private var error: String?

    private var total: Int? {
        var sum = 0
        for p in prizes {
            guard let c = Money.cents(amounts[p.participantId] ?? "") else { return nil }
            sum += c
        }
        return sum
    }

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Split", back: { T1Overlays.shared.dismissPanel() }) {
                LabelText("\(total.map(Money.text) ?? "–") / \(Money.text(poolCents))", color: (total ?? .max) <= poolCents ? T1.text : T1.danger)
            }
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(prizes) { p in
                        MoneyField(label: "\(Leagues.ordinal(p.place)) · \(p.name)", text: Binding(
                            get: { amounts[p.participantId] ?? "" }, set: { amounts[p.participantId] = $0 }))
                    }
                    if let error { Notice(error, error: true) }
                }
            }
            BigAction(text: "Save split", enabled: (total ?? .max) <= poolCents, busy: busy, accent: true) { save() }
        }
        .foregroundStyle(T1.text)
        .onAppear { if amounts.isEmpty { amounts = Dictionary(uniqueKeysWithValues: prizes.map { ($0.participantId, Money.typed($0.amountCents)) }) } }
    }

    private func save() {
        busy = true
        let rows = prizes.map { (participantId: $0.participantId, cents: Money.cents(amounts[$0.participantId] ?? "") ?? 0) }
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Repo.setPrizes(eventId, rows: rows)
                await EventSide.of(eventId).refreshMoney()
                T1Overlays.shared.dismissPanel()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: a league's cut

/// Under a league's season: `Prize pool … $1,400` when the season takes a cut of each entry.
struct LeaguePoolRow: View {
    let seasonId: String
    @State private var money: LeagueMoney?

    var body: some View {
        Group {
            Color.clear.frame(height: 1).task(id: seasonId) { money = try? await Repo.leagueMoney(seasonId) }
            if let money, money.entryCutCents > 0 {
                ListRow(title: "Prize pool", detail: "\(Money.text(money.entryCutCents)) an entry") {
                    Text(Money.text(money.poolCents)).font(T1.mono(16)).monospacedDigit()
                }
            }
        }
    }
}

/// The organizer's tools → Dues: what each event's host owes the league and what's been received.
struct LeagueDuesRow: View {
    let seasonId: String
    let season: String
    @State private var money: LeagueMoney?

    var body: some View {
        Group {
            LoadOnce {
                await PaymentsGate.shared.load()
                if PaymentsGate.shared.enabled { money = try? await Repo.leagueMoney(seasonId) }
            }
            if PaymentsGate.shared.enabled, let money, money.events != nil, money.entryCutCents > 0 || !(money.events ?? []).isEmpty {
                Section1("Dues · \(season)")
                Button {
                    T1Overlays.shared.present(full: true) { LeagueDuesPanel(seasonId: seasonId, money: money) { self.money = $0 }.screen("league_dues") }
                } label: {
                    ListRow(title: "Dues", detail: "\(Money.text(money.entryCutCents)) an entry") {
                        HStack(spacing: 8) {
                            LabelText("\(Money.text(money.receivedCents ?? 0)) of \(Money.text(money.poolCents))", color: T1.text)
                            T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct LeagueDuesPanel: View {
    let seasonId: String
    @State var money: LeagueMoney
    var changed: (LeagueMoney) -> Void = { _ in }
    @State private var error: String?
    @State private var typing: LeagueMoney.Due?
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Dues", back: { T1Overlays.shared.dismissPanel() })
            ScrollView {
                VStack(spacing: 1) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabelText("Received")
                        Text(Money.text(money.receivedCents ?? 0)).font(T1.mono(44)).monospacedDigit().foregroundStyle(T1.accent)
                        LabelText("of \(Money.text(money.poolCents)) owed · \(Money.text(money.entryCutCents)) an entry")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20).background(T1.surface)
                    if let error { Notice(error, error: true) }
                    if (money.events ?? []).isEmpty { ListRow(title: "No paid entries yet") }
                    ForEach(money.events ?? []) { e in
                        Button { menu(e) } label: {
                            ListRow(title: e.name, detail: "\(e.entries ?? 0) entries · owed \(Money.text(e.owedCents))") {
                                LabelText(e.receivedCents >= e.owedCents && e.owedCents > 0 ? "Received" : e.receivedCents > 0 ? "\(Money.text(e.receivedCents)) in" : "Mark received",
                                          color: e.receivedCents >= e.owedCents && e.owedCents > 0 ? T1.accent : T1.text)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(T1.text)
        .alert("Received from \(typing?.name ?? "the event")", isPresented: Binding(get: { typing != nil }, set: { if !$0 { typing = nil } })) {
            TextField("Amount in USD", text: $typed).keyboardType(.decimalPad)
            Button("Save") { if let e = typing, let c = Money.cents(typed) { mark(e, c) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func menu(_ e: LeagueMoney.Due) {
        T1Overlays.shared.showMenu(e.name, message: "Owed \(Money.text(e.owedCents))", [
            T1MenuItem(title: "Received \(Money.text(e.owedCents))", checked: e.receivedCents == e.owedCents && e.owedCents > 0) { mark(e, e.owedCents) },
            T1MenuItem(title: "Another amount") { typed = Money.typed(e.receivedCents); typing = e },
            T1MenuItem(title: "Not received", checked: e.receivedCents == 0) { mark(e, 0) },
        ])
    }

    private func mark(_ e: LeagueMoney.Due, _ cents: Int) {
        Task { @MainActor in
            do {
                try await Repo.markDue(e.eventId, receivedCents: cents)
                if let m = try? await Repo.leagueMoney(seasonId) { money = m; changed(m) }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
