import SwiftUI

/// Event type → format → product (set or cube) → teams → rounds → players, on one scrolling form.
/// The server names the event from these choices ("Draft · Duskmourn · Fri 17 Oct"); rounds are always 50 minutes.
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
    @State private var showClock = true
    @State private var includeMe = true
    @State private var myName: String?
    @State private var guests: [String] = []
    @State private var venue = ""
    @State private var nearby = true
    @State private var busy = false
    @State private var error: String?

    private var format: FormatOption { kind == .constructed ? constructedFormat : limitedFormat }
    private var isLimited: Bool { kind == .limited }
    private var trimmedCubeUrl: String { cubeUrl.trimmingCharacters(in: .whitespaces) }
    private var cubeUrlValid: Bool { EventProduct.cubeUrlValid(cubeUrl) }

    /// What the server will call it.
    private var previewName: String {
        let label = EventNaming.label(
            format: format.rawValue, formatOther: formatOther,
            setName: isLimited && product == .set ? (chosenSet?.name ?? typedSetName) : nil,
            cubeName: isLimited && product == .cube ? cubeName : nil)
        return "\(label) · \(EventNaming.day())"
    }

    private var valid: Bool {
        if format == .otherConstructed && formatOther.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if isLimited && product == .cube {
            return !cubeName.trimmingCharacters(in: .whitespaces).isEmpty && cubeUrlValid
        }
        return true
    }

    var body: some View {
        T1Screen {
            Bar(title: "New event", subtitle: previewName) { BarButton("Cancel") { dismiss() } }
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
                    RoundTimerSwitch(isOn: $showClock)

                    PlayersFields(includeMe: $includeMe, myName: myName, guests: $guests)

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
            async let name = Repo.myDisplayName()
            let sets = (try? await Repo.draftableSets(query: "")) ?? []
            if sets.isEmpty { setsUnavailable = true }
            myName = await name
        }
    }

    private func create() {
        busy = true
        error = nil
        let limitedSet = isLimited && product == .set
        let cube = isLimited && product == .cube
        let draft = NewEventDraft(
            name: nil,
            formatName: format.rawValue,
            rounds: rounds,
            showClock: showClock,
            setCode: limitedSet ? chosenSet?.code : nil,
            setName: limitedSet ? (chosenSet?.name ?? typedSetName) : nil,
            cubeName: cube ? cubeName : nil,
            cubeUrl: cube ? trimmedCubeUrl : nil,
            teamSize: format.isTeam ? teamSize : nil,
            formatOther: format == .otherConstructed ? formatOther : nil
        )
        let guests = guests
        let includeMe = includeMe
        Task {
            defer { busy = false }
            do {
                let created = try await Repo.createEventV2(draft, includeMe: includeMe, guests: guests)
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

/// "Round timer · 50 min": on shows clocks to everyone; off hides them. Rounds run 50 minutes either way.
struct RoundTimerSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        T1Switch(title: "Round timer · 50 min", detail: isOn ? "Clocks shown" : "Clocks hidden", isOn: $isOn)
    }
}

/// Create: you (on by default) plus players by name only. People with accounts are invited after.
struct PlayersFields: View {
    @Binding var includeMe: Bool
    let myName: String?
    @Binding var guests: [String]
    @State private var newName = ""

    private var count: Int { guests.count + (includeMe ? 1 : 0) }
    private var trimmed: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
    private var duplicate: Bool {
        let t = trimmed.lowercased()
        return guests.contains { $0.lowercased() == t } || (includeMe && myName?.lowercased() == t)
    }

    var body: some View {
        Section1("Players · \(count)")
        T1Switch(title: myName.map { "You · \($0)" } ?? "You", detail: includeMe ? "Playing" : "Not playing", isOn: $includeMe)
        ForEach(Array(guests.enumerated()), id: \.offset) { index, name in
            ListRow(title: name, detail: "Guest · no account") {
                Button { guests.remove(at: index) } label: { LabelText("Remove", color: T1.danger) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(name)")
            }
        }
        AddByNameRow(text: $newName, enabled: !trimmed.isEmpty && !duplicate) { add() }
        if duplicate && !trimmed.isEmpty { Notice("\(trimmed) is already on the list.", error: true) }
        Notice("Add people with accounts on the next screen; they get an invitation.")
    }

    private func add() {
        guard !trimmed.isEmpty, !duplicate else { return }
        guests.append(String(trimmed.prefix(40)))
        newName = ""
    }
}

/// A name field with an Add button beside it; Return adds too.
struct AddByNameRow: View {
    @Binding var text: String
    var label = "Add a player by name"
    let enabled: Bool
    let add: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            VStack(alignment: .leading, spacing: 4) {
                LabelText(label)
                TextField("", text: $text)
                    .font(T1.mono(15)).tint(T1.accent)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { if enabled { add() } }
                    .onChange(of: text) { _, v in if v.count > 40 { text = String(v.prefix(40)) } }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T1.surface)
            Button(action: add) {
                LabelText("Add", color: enabled ? T1.ink : T1.muted)
                    .frame(width: 72).frame(maxHeight: .infinity)
                    .background(enabled ? T1.accent : T1.disabled)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
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
                    SetRow(set: chosenSet) {
                        LabelText(chosenSet == nil ? "Choose ›" : "Change ›", color: T1.accent)
                    }
                }
                .buttonStyle(.plain)
            }
        case .cube:
            CubeFields(cubeName: $cubeName, cubeUrl: $cubeUrl)
        }
    }
}

/// A set with its symbol: "Duskmourn: House of Horror" / "DSK · 2024".
struct SetRow<Trailing: View>: View {
    let set: DraftableSet?
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let set {
                SetIcon(code: set.code, uri: set.iconSvgUri, size: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(set?.name ?? "Choose a set").font(T1.mono(14)).lineLimit(1)
                LabelText(detail ?? set.map { "Set · \($0.code.uppercased())" } ?? "Set")
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(T1.surface)
        .contentShape(Rectangle())
    }
}

/// Cube: your recent cubes, a Cube Cobra link (the name fills in from Cube Cobra), and the name.
/// (Your Table 1 cubes join this list once the Library keeps cubes.)
struct CubeFields: View {
    @Binding var cubeName: String
    @Binding var cubeUrl: String
    @State private var recent: [RecentCube] = []
    @State private var lookup: LookupState = .idle
    /// The link the last lookup answered for, so writing its canonical form back doesn't look it up again.
    @State private var settledUrl: String?

    enum LookupState: Equatable { case idle, looking, found(Int?), failed(String) }

    var body: some View {
        if !recent.isEmpty {
            Section1("Recent cubes")
            ForEach(recent) { cube in
                Button { use(cube) } label: {
                    ListRow(title: cube.cubeName) {
                        if isCurrent(cube) { LabelText("Selected", color: T1.accent) } else { LabelText("Use", color: T1.text) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        Section1("Cube")
        Field(label: "Cube Cobra link", text: $cubeUrl, url: true)
        switch lookup {
        case .idle: EmptyView()
        case .looking: Notice("Looking it up on Cube Cobra…")
        case .found(let cards): Notice("Found on Cube Cobra\(cards.map { " · \($0) cards" } ?? "").")
        case .failed(let message): Notice(message, error: true)
        }
        Field(label: "Cube name", text: $cubeName)
            .onChange(of: cubeName) { _, v in if v.count > 80 { cubeName = String(v.prefix(80)) } }
        if !EventProduct.cubeUrlValid(cubeUrl) && lookup != .looking { Notice("Paste a Cube Cobra link (https://cubecobra.com/…)", error: true) }
        Color.clear.frame(height: 0)
            .task { recent = await Repo.recentCubes() }
            .task(id: cubeUrl) { await lookUp() }
    }

    private func isCurrent(_ cube: RecentCube) -> Bool {
        cube.cubeName == cubeName.trimmingCharacters(in: .whitespaces) && (cube.cubeUrl ?? "") == cubeUrl.trimmingCharacters(in: .whitespaces)
    }

    private func use(_ cube: RecentCube) {
        settledUrl = cube.cubeUrl ?? ""
        cubeName = cube.cubeName
        cubeUrl = cube.cubeUrl ?? ""
        lookup = .idle
    }

    private func lookUp() async {
        let link = cubeUrl.trimmingCharacters(in: .whitespaces)
        guard !link.isEmpty else { lookup = .idle; return }
        guard link != settledUrl else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        lookup = .looking
        do {
            let cube = try await Repo.lookupCube(link)
            guard !Task.isCancelled else { return }
            settledUrl = cube.url
            cubeName = cube.name
            cubeUrl = cube.url
            lookup = .found(cube.cardCount)
        } catch {
            guard !Task.isCancelled else { return }
            lookup = .failed(error.localizedDescription)
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
            Bar(title: "Set", subtitle: "Newest first", back: { dismiss() }) {
                if selected != nil {
                    BarButton("Clear") {
                        selected = nil
                        dismiss()
                    }
                }
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
                        SetRow(set: s, detail: detail(s)) {
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
