import SwiftUI

/// Event type → format → product (set or cube) → teams → rounds → name, on one scrolling form.
struct CreateEventView: View {
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    @State private var kind: EventKind = .limited
    @State private var constructedFormat: FormatOption = .modern
    @State private var limitedFormat: FormatOption = .draft
    @State private var formatOther = ""
    @State private var product: EventProduct = .set
    @State private var chosenSet: DraftableSet?
    @State private var typedSetName = ""
    /// draftable_sets came back empty (or failed): type the set's name instead.
    @State private var setsUnavailable = false
    @State private var choosingSet = false
    @State private var cubeName = ""
    @State private var cubeUrl = ""
    @State private var teamSize = 3
    @State private var rounds = 3
    @State private var minutes = 50
    /// Nil until the organizer types a name; until then it follows the format and product.
    @State private var customName: String?
    @State private var venue = ""
    @State private var nearby = true
    @State private var busy = false
    @State private var error: String?

    private var format: FormatOption { kind == .constructed ? constructedFormat : limitedFormat }
    private var isLimited: Bool { kind == .limited }
    private var trimmedCubeUrl: String { cubeUrl.trimmingCharacters(in: .whitespaces) }
    private var cubeUrlValid: Bool { EventProduct.cubeUrlValid(cubeUrl) }
    private var name: String { (customName ?? autoName).trimmingCharacters(in: .whitespaces) }

    /// "Modern night", "Duskmourn draft", "Vintage Cube team draft".
    private var autoName: String {
        if !isLimited {
            let other = formatOther.trimmingCharacters(in: .whitespaces)
            return "\(format == .otherConstructed ? (other.isEmpty ? "Constructed" : other) : format.label) night"
        }
        let productName: String
        switch product {
        case .set:
            let full = chosenSet?.name ?? typedSetName
            productName = String(full.split(separator: ":").first ?? "").trimmingCharacters(in: .whitespaces)
        case .cube:
            productName = cubeName.trimmingCharacters(in: .whitespaces)
        }
        return productName.isEmpty ? "\(format.label) night" : "\(productName) \(format.label.lowercased())"
    }

    private var valid: Bool {
        guard !name.isEmpty else { return false }
        if format == .otherConstructed && formatOther.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if isLimited && product == .cube {
            return !cubeName.trimmingCharacters(in: .whitespaces).isEmpty && cubeUrlValid
        }
        return true
    }

    var body: some View {
        T1Screen {
            Bar(title: "New event", subtitle: format.label) { BarButton("Cancel") { dismiss() } }
            ScrollView {
                VStack(spacing: 1) {
                    FormatFields(kind: $kind, constructedFormat: $constructedFormat, limitedFormat: $limitedFormat,
                                 formatOther: $formatOther)

                    if isLimited {
                        ProductFields(product: $product, chosenSet: chosenSet, typedSetName: $typedSetName,
                                      cubeName: $cubeName, cubeUrl: $cubeUrl, setsUnavailable: setsUnavailable) {
                            choosingSet = true
                        }
                    }

                    if format.isTeam {
                        TeamSizeFields(format: format, teamSize: $teamSize)
                    }

                    Section1("Rounds")
                    T1Stepper(label: "Rounds", value: $rounds, range: 1...15)
                    T1Stepper(label: "Round length", value: $minutes, range: 10...180, step: 5, unit: " min")

                    Section1("Name")
                    Field(label: "Event name", text: Binding(get: { customName ?? autoName }, set: { customName = $0 }))

                    Section1("Who can find it")
                    Field(label: "Venue (optional)", text: $venue)
                    T1Segmented(options: [(value: true, label: "Nearby + QR"), (value: false, label: "QR only")], selection: $nearby)
                    Notice(nearby
                        ? "Players within 150 m can find and join it, and players nearby who turned on alerts get a Join / Decline notification."
                        : "Only people who scan your QR code can join.")
                    if let error { Notice(error, error: true) }
                }
            }
            BigAction(text: "Create event", enabled: valid, busy: busy, accent: true) { create() }
        }
        .navigationDestination(isPresented: $choosingSet) { SetPickerScreen(selected: $chosenSet) }
        .task {
            // No sets synced on the server: fall back to typing the set's name.
            let sets = (try? await Repo.draftableSets(query: "")) ?? []
            if sets.isEmpty { setsUnavailable = true }
        }
    }

    private func create() {
        busy = true
        error = nil
        let limitedSet = isLimited && product == .set
        let cube = isLimited && product == .cube
        let draft = NewEventDraft(
            name: name,
            formatName: format.rawValue,
            rounds: rounds,
            roundMinutes: minutes,
            setCode: limitedSet ? chosenSet?.code : nil,
            setName: limitedSet ? (chosenSet?.name ?? typedSetName) : nil,
            cubeName: cube ? cubeName : nil,
            cubeUrl: cube ? trimmedCubeUrl : nil,
            teamSize: format.isTeam ? teamSize : nil,
            formatOther: format == .otherConstructed ? formatOther : nil
        )
        Task {
            defer { busy = false }
            do {
                let created = try await Repo.createEventV2(draft)
                // Pin it where the organizer stands; for nearby events this also alerts opted-in players around.
                if let fix = await LocationFix.shared.current() {
                    try? await Repo.setEventLocation(
                        eventId: created.eventId, lat: fix.lat, lng: fix.lng,
                        venue: venue.isEmpty ? nil : venue, nearby: nearby
                    )
                }
                // Straight to inviting people; Back lands on the new event.
                path = [.event(created.eventId), .addPlayers(created.eventId)]
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Wire values for create_event_v2's p_format_name.
enum FormatOption: String, CaseIterable, Identifiable {
    case standard, pioneer, modern, legacy, vintage, pauper, premodern
    case canadianHighlander = "canadian_highlander"
    case otherConstructed = "other_constructed"
    case draft
    case teamDraft = "team_draft"
    case sealed
    case teamSealed = "team_sealed"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: "Standard"
        case .pioneer: "Pioneer"
        case .modern: "Modern"
        case .legacy: "Legacy"
        case .vintage: "Vintage"
        case .pauper: "Pauper"
        case .premodern: "Premodern"
        case .canadianHighlander: "Canadian Highlander"
        case .otherConstructed: "Other"
        case .draft: "Draft"
        case .teamDraft: "Team draft"
        case .sealed: "Sealed"
        case .teamSealed: "Team sealed"
        }
    }
    var isTeam: Bool { self == .teamDraft || self == .teamSealed }

    static let constructed: [FormatOption] = [.standard, .pioneer, .modern, .legacy, .vintage, .pauper, .premodern,
                                              .canadianHighlander, .otherConstructed]
    static let limited: [FormatOption] = [.draft, .teamDraft, .sealed, .teamSealed]
}

enum EventKind: String, CaseIterable, Identifiable {
    case constructed, limited
    var id: String { rawValue }
    var label: String { self == .constructed ? "Constructed" : "Limited" }
}

/// What a limited event plays with.
enum EventProduct: String, CaseIterable, Identifiable {
    case set, cube
    var id: String { rawValue }
    var label: String { self == .set ? "Set" : "Cube" }

    /// CubeCobra links are optional; when given they start with https://.
    static func cubeUrlValid(_ url: String) -> Bool {
        let t = url.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.lowercased().hasPrefix("https://")
    }
}

// MARK: shared form pieces (Create event and the organizer's Setup → Details)

/// Type, then format: Constructed is a menu list (+ Other with "Format name"); Limited is a segmented row.
struct FormatFields: View {
    @Binding var kind: EventKind
    @Binding var constructedFormat: FormatOption
    @Binding var limitedFormat: FormatOption
    @Binding var formatOther: String

    var body: some View {
        Section1("Type")
        T1Segmented(options: EventKind.allCases.map { (value: $0, label: $0.label) }, selection: $kind)

        Section1("Format")
        if kind == .limited {
            T1Segmented(options: FormatOption.limited.map { (value: $0, label: $0.label) }, selection: $limitedFormat)
        } else {
            Button { chooseConstructedFormat() } label: {
                ListRow(title: "Format", detail: "Constructed") {
                    LabelText("\(constructedFormat.label) ›", color: T1.accent)
                }
            }
            .buttonStyle(.plain)
            if constructedFormat == .otherConstructed {
                Field(label: "Format name", text: $formatOther)
                    .onChange(of: formatOther) { _, v in if v.count > 40 { formatOther = String(v.prefix(40)) } }
            }
        }
    }

    private func chooseConstructedFormat() {
        let binding = $constructedFormat
        T1Overlays.shared.showMenu("Format", FormatOption.constructed.map { option in
            T1MenuItem(title: option.label, checked: option == binding.wrappedValue) { binding.wrappedValue = option }
        })
    }
}

/// Limited events: a set (picked from draftable_sets, or typed when none are synced) or a cube.
struct ProductFields: View {
    @Binding var product: EventProduct
    let chosenSet: DraftableSet?
    @Binding var typedSetName: String
    @Binding var cubeName: String
    @Binding var cubeUrl: String
    let setsUnavailable: Bool
    let chooseSet: () -> Void

    var body: some View {
        Section1("Product")
        T1Segmented(options: EventProduct.allCases.map { (value: $0, label: $0.label) }, selection: $product)
        switch product {
        case .set:
            if setsUnavailable {
                Field(label: "Set name", text: $typedSetName)
                    .onChange(of: typedSetName) { _, v in if v.count > 80 { typedSetName = String(v.prefix(80)) } }
            } else {
                Button { chooseSet() } label: {
                    ListRow(title: chosenSet?.name ?? "Choose a set",
                            detail: chosenSet.map { "Set · \($0.code.uppercased())" } ?? "Set") {
                        LabelText(chosenSet == nil ? "Choose ›" : "Change ›", color: T1.accent)
                    }
                }
                .buttonStyle(.plain)
            }
        case .cube:
            Field(label: "Cube name", text: $cubeName)
                .onChange(of: cubeName) { _, v in if v.count > 80 { cubeName = String(v.prefix(80)) } }
            Field(label: "CubeCobra link (optional)", text: $cubeUrl, url: true)
            if !EventProduct.cubeUrlValid(cubeUrl) { Notice("Links start with https://", error: true) }
        }
    }
}

/// Team formats: 3 or 4 players per team.
struct TeamSizeFields: View {
    let format: FormatOption
    @Binding var teamSize: Int

    var body: some View {
        Section1("Players per team")
        T1Segmented(options: [(value: 3, label: "3"), (value: 4, label: "4")], selection: $teamSize)
        Notice(format == .teamDraft ? "Two teams of \(teamSize) draft at one table." : "Teams of \(teamSize) play team against team.")
    }
}

/// Pushed screen: search draftable sets, newest first.
struct SetPickerScreen: View {
    @Binding var selected: DraftableSet?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sets: [DraftableSet] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: "Set", subtitle: "Newest first") {
                if selected != nil {
                    BarButton("Clear") {
                        selected = nil
                        dismiss()
                    }
                }
                BarButton("Back") { dismiss() }
            }
            T1SearchField(text: $query, prompt: "Search sets")
            HairlineList {
                if let error {
                    Notice(error, error: true)
                } else if sets.isEmpty {
                    Notice(loading ? "Loading…" : query.isEmpty ? "No sets available" : "No sets match \u{201C}\(query)\u{201D}")
                }
                ForEach(sets) { s in
                    Button {
                        selected = s
                        dismiss()
                    } label: {
                        ListRow(title: s.name, detail: detail(s)) {
                            if selected?.code == s.code { LabelText("Selected", color: T1.accent) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: query) {
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            loading = true
            do {
                sets = try await Repo.draftableSets(query: query)
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            loading = false
        }
    }

    private func detail(_ s: DraftableSet) -> String {
        var parts = [s.code.uppercased()]
        if let year = s.releasedAt?.prefix(4) { parts.append(String(year)) }
        if let type = s.setType { parts.append(type.replacingOccurrences(of: "_", with: " ")) }
        return parts.joined(separator: " · ")
    }
}
