import SwiftUI
import Supabase

// A season's final and alerts for new public events (contract/teams-finals-alerts-2026-11-13.md §§ 3–4): the
// Qualified row and list of Setup → Players, and the Alerts row and screen of Find → Events.

// MARK: a season's final

/// On a final you organize: `Qualified · 3 of 23 in`, opening the list. Hidden for every other event (the server
/// refuses), and on a server without it.
struct QualifiedRow: View {
    let eventId: String
    @State private var status: FinalStatus?

    var body: some View {
        Group {
            LoadOnce { status = try? await Repo.finalStatus(eventId) }
            if let status {
                Button {
                    T1Overlays.shared.present(full: true) { QualifiedPanel(eventId: eventId, status: status) { self.status = $0 }.screen("final_qualified") }
                } label: {
                    ListRow(title: "Qualified") {
                        HStack(spacing: 8) {
                            LabelText(status.line, color: T1.text)
                            T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Qualified (how each got in, and where their invitation stands) with Invite the qualified, then Next in line with
/// Invite per row, to pass an invitation down.
struct QualifiedPanel: View {
    let eventId: String
    @State var status: FinalStatus
    var changed: (FinalStatus) -> Void = { _ in }
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Qualified", subtitle: status.line, back: { T1Overlays.shared.dismissPanel() })
            if let error { Notice(error, error: true) }
            ScrollView {
                LazyVStack(spacing: 1) {
                    if status.qualified.isEmpty { ListRow(title: "No one has qualified yet") }
                    ForEach(status.qualified) { r in row(r) }
                    if !status.next.isEmpty {
                        Section1("Next in line")
                        ForEach(status.next) { r in row(r) }
                    }
                }
            }
            BigAction(text: status.toInvite > 0 ? "Invite the qualified · \(status.toInvite)" : "Everyone is invited", enabled: status.toInvite > 0,
                      busy: busy, accent: true) { invite(nil) }
        }
        .foregroundStyle(T1.text)
        .task { await load() }
    }

    private func row(_ r: FinalRow) -> some View {
        ListRow(title: r.name, detail: Self.detail(r), avatar: AvatarView(name: r.name, userId: r.userId)) {
            switch r.state {
            case "in": LabelText("In", color: T1.accent)
            case "invited": LabelText("Invited")
            case "declined": LabelText("Declined")
            case "guest": LabelText("Guest")
            default: BarButton(busy ? "…" : "Invite") { invite([r.key]) }
            }
        }
    }

    /// `#4 · 36 PTS · POINTS`.
    static func detail(_ r: FinalRow) -> String {
        [r.rank.map { "#\($0)" }, r.points.map { "\($0) pts" }, r.how.map { $0 == "winner" ? "Winner" : "Points" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func invite(_ keys: [String]?) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Repo.finalInvite(eventId, keys: keys)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func load() async {
        guard let s = try? await Repo.finalStatus(eventId) else { return }
        status = s
        changed(s)
    }
}

// MARK: alerts

/// Find → Events ends with `Alerts · MODERN, LIMITED · 50 KM`. Hidden until the server answers.
struct AlertsRow: View {
    @State private var alerts: EventAlerts?

    var body: some View {
        Group {
            LoadOnce { alerts = try? await Repo.eventAlerts() }
            if let alerts {
                Button {
                    T1Overlays.shared.present(full: true) { AlertsPanel(alerts: alerts) { self.alerts = $0 }.screen("event_alerts") }
                } label: {
                    ListRow(title: "Alerts") {
                        HStack(spacing: 8) {
                            LabelText(AlertRules.line(alerts), color: alerts.on ? T1.text : T1.muted)
                            T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Alerts for new public events: On, Formats (several), Area (asked only on its tap), Distance. Every change saves.
struct AlertsPanel: View {
    @State var alerts: EventAlerts
    var changed: (EventAlerts) -> Void = { _ in }
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Alerts", back: { T1Overlays.shared.dismissPanel() })
            ScrollView {
                VStack(spacing: 1) {
                    T1Switch(title: "New public events", detail: AlertRules.line(alerts), isOn: Binding(get: { alerts.on }, set: { on in
                        alerts.on = on
                        save(["on": .bool(on)])
                    }))
                    if let error { Notice(error, error: true) }

                    Section1("Formats")
                    FilterRow(cells: [
                        FilterCell(name: "Formats", value: alerts.formats.isEmpty ? "Every format" : alerts.formats.count == 1 ? Leagues.label(alerts.formats[0]) : "\(alerts.formats.count) formats",
                                   options: [SelectorOption(value: LimitedFilter.any, label: "Every format")]
                                       + Leagues.formatKeys.map { SelectorOption(value: $0.key, label: $0.label) },
                                   current: nil, picked: alerts.formats) { v in toggle(v) },
                    ], event: nil, screen: "alerts_format_picker")

                    Section1("Area")
                    ListRow(title: alerts.hasArea ? "Around where you set it" : "No area", detail: alerts.hasArea ? "Kept to about 10 km" : nil) {
                        if alerts.hasArea { BarButton("Forget area") { forget() } }
                    }
                    Ghost(text: busy ? "Finding you…" : "Use where I am now") { useHere(then: nil) }

                    Section1("Distance")
                    T1Segmented(options: [(value: 0, label: "Anywhere")] + AlertRules.distances.map { (value: $0, label: "\($0) km") },
                                selection: Binding(get: { alerts.km ?? 0 }, set: { km in setDistance(km) }), scroll: true)
                    Notice("Up to five a week.")
                }
            }
        }
        .foregroundStyle(T1.text)
    }

    private func toggle(_ key: String) {
        var set = alerts.formats
        if key == LimitedFilter.any { set = [] } else if set.contains(key) { set.removeAll { $0 == key } } else { set.append(key) }
        let ordered = Leagues.formatKeys.map(\.key).filter(set.contains)
        alerts.formats = ordered
        save(["formats": .array(ordered.map { .string($0) })])
    }

    /// A distance needs an area: without one, the area is asked for first.
    private func setDistance(_ km: Int) {
        if km > 0, !alerts.hasArea { useHere(then: km); return }
        alerts.km = km > 0 ? km : nil
        save(["km": km > 0 ? .integer(km) : .null])
    }

    /// Location is asked for only here, on this tap; the area is kept rounded to 0.1°.
    private func useHere(then km: Int?) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            guard let fix = await LocationFix.shared.current() else {
                error = "Turn on location to set your area."
                return
            }
            var patch: [String: AnyJSON] = ["lat": .double(Leagues.rough(fix.lat)), "lng": .double(Leagues.rough(fix.lng))]
            if let km { patch["km"] = .integer(km) }
            await send(patch)
        }
    }

    private func forget() { save(["place": .null]) }

    private func save(_ patch: [String: AnyJSON]) { Task { @MainActor in await send(patch) } }

    @MainActor
    private func send(_ patch: [String: AnyJSON]) async {
        do {
            alerts = try await Repo.setEventAlerts(patch)
            error = nil
            changed(alerts)
        } catch {
            self.error = error.localizedDescription
            if let a = try? await Repo.eventAlerts() { alerts = a }
        }
    }
}
