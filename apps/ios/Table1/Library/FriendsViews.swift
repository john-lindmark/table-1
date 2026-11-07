import SwiftUI

/* Friends, profiles, sharing and trade matches screens (contract/friends-sharing-2026-10-18.md). They ride on
   LibraryRoute (`.social`) so the Collection tab and the Account tab can both push them, and a match can open
   the trade editor in place. */

enum SocialRoute: Hashable {
    case friends
    case profile(String) // user id
    case profileCards(String, String, String?, String, SharedList? = nil) // user id, section, binder/list id, title, deck/cube
    case sharing
    case sharingItems(String) // binder / deck / cube
    case share(ShareTarget) // the Share screen for one part of your Library
    case sharedLink(String) // a share link's token (table-1.site/l/<token>)
    case matches
    case match(String) // user id
    case notices
    case review
    case bugs
    case bug(Int)
    case following
    case followChanges(String, String) // binder / deck / cube, its id

    /// contract/telemetry-2026-10-15.md; never carries ids.
    var screenName: String {
        switch self {
        case .friends: "friends"
        case .profile: "profile"
        case .profileCards: "profile_cards"
        case .sharing, .sharingItems: "sharing"
        case .share: "share"
        case .sharedLink: "shared_link"
        case .matches: "trade_matches"
        case .match: "trade_match"
        case .notices: "moderation_notices"
        case .review: "moderation_review"
        case .bugs: "bugs"
        case .bug: "bug"
        case .following: "following"
        case .followChanges: "follow_changes"
        }
    }
}

struct SocialDestination: View {
    let route: SocialRoute
    @Binding var path: [LibraryRoute]

    var body: some View {
        switch route {
        case .friends: FriendsView(path: $path)
        case .profile(let id): ProfileScreen(userId: id, path: $path)
        case .profileCards(let id, let kind, let item, let title, let list):
            ProfileCardsView(userId: id, section: ProfileSection(kind: kind, id: item), title: title, list: list, path: $path)
        case .sharing: SharingView(path: $path)
        case .sharingItems(let kind): SharingItemsView(kind: kind)
        case .share(let target): ShareView(target: target, path: $path)
        case .sharedLink(let token): SharedLinkView(token: token, path: $path)
        case .matches: TradeMatchesView(path: $path)
        case .match(let id): TradeMatchView(userId: id, path: $path)
        case .notices: NoticesView()
        case .review: ReviewView()
        case .bugs: BugsView(path: $path)
        case .bug(let id): BugView(id: id)
        case .following: FollowingView(path: $path)
        case .followChanges(let kind, let id): FollowChangesView(kind: kind, id: id, path: $path)
        }
    }
}

private func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
    "\(n.formatted()) \(n == 1 ? one : many ?? one + "s")"
}

/// Small accent / plain action at the end of a row.
private struct RowAction: View {
    let text: String
    var accent = false
    var danger = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            LabelText(text, color: accent ? T1.ink : danger ? T1.danger : T1.text)
                .fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(accent ? T1.accent : T1.surfaceHover)
        }
        .buttonStyle(.plain)
    }
}

// MARK: account and library rows

/// Account tab: Friends, Sharing and your own profile.
struct AccountSocialRows: View {
    @Binding var path: [LibraryRoute]
    private var store: FriendsStore { FriendsStore.shared }

    var body: some View {
        let friends = store.list?.friends.count ?? 0, waiting = store.requestsWaiting
        Section1("Friends and sharing")
        Button { path.append(.social(.friends)) } label: {
            ListRow(title: "Friends", detail: [plural(friends, "friend"), waiting > 0 ? "\(waiting) waiting" : nil].compactMap { $0 }.joined(separator: " · ")) {
                if waiting > 0 { LabelText("\(waiting) new", color: T1.accent) }
            }
        }.buttonStyle(.plain)
        Button { path.append(.social(.sharing)) } label: {
            ListRow(title: "Sharing", detail: store.sharing.map(SharingRules.summary) ?? "Who sees your profile and Library")
        }.buttonStyle(.plain)
        if let me = Repo.userId {
            Button { path.append(.social(.profile(me))) } label: {
                ListRow(title: "Your profile", detail: "Name, photo and what you share")
            }.buttonStyle(.plain)
        }
    }
}

// MARK: friends

struct FriendsView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }
    @State private var busy: String?
    /// How you know people (played-with suggestions), for request rows.
    @State private var together: [String: Int] = [:]

    var body: some View {
        let l = store.list
        T1Screen {
            Bar(title: "Friends", subtitle: l.map { [plural($0.friends.count, "friend"), $0.incoming.isEmpty ? nil : "\($0.incoming.count) waiting"].compactMap { $0 }.joined(separator: " · ") },
                back: { dismiss() }) {
                BarButton("Add") { add() }
            }
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                Button { add() } label: {
                    ListRow(title: "Add a friend", detail: "Played with you, a name or an email")
                }.buttonStyle(.plain)
                if let l {
                    if !l.incoming.isEmpty {
                        Section1("Requests · \(l.incoming.count)")
                        ForEach(l.incoming) { p in
                            row(p, .incoming, detail: ["Asked you", together[p.userId].map { plural($0, "event") + " together" }]
                                    .compactMap { $0 }.joined(separator: " · ")) {
                                HStack(spacing: 1) {
                                    RowAction(text: "Accept", accent: true) { run(p.userId) { try await store.respond(p.userId, accept: true) } }
                                    RowAction(text: "Ignore") { run(p.userId) { try await store.respond(p.userId, accept: false) } }
                                    RowAction(text: "More") { PersonActions.menu(p, .incoming, from: "request") }
                                }
                            }
                        }
                    }
                    Section1("Friends · \(l.friends.count)")
                    if l.friends.isEmpty {
                        Notice("No friends yet. Friends see what you share with them, show up first in Add players, and their trades are matched against your wants.")
                    }
                    ForEach(l.friends) { p in
                        Button { open(p) } label: {
                            ListRow(title: p.displayName, detail: p.handle.map { "@\($0)" }, avatar: AvatarView(name: p.displayName, userId: p.userId))
                        }
                        .buttonStyle(.plain)
                        .personMenu { PersonActions.menu(p, .friend, from: "friends") }
                    }
                    if !l.outgoing.isEmpty {
                        Section1("Sent · \(l.outgoing.count)")
                        ForEach(l.outgoing) { r in
                            if let p = r.person {
                                row(p, .requested, detail: "Requested") {
                                    RowAction(text: "Cancel") { run(r.id) { try await store.cancel(r) } }
                                }
                            } else {
                                // Asked by email: only the address (the server never says whose account it is).
                                ListRow(title: r.label, detail: busy == r.id ? "Working…" : "Asked by email") {
                                    RowAction(text: "Cancel") { run(r.id) { try await store.cancel(r) } }
                                }
                            }
                        }
                    }
                    if !l.blocked.isEmpty {
                        Section1("Blocked · \(l.blocked.count)")
                        ForEach(l.blocked) { p in
                            row(p, .blocked, detail: "Can't find you, see your Library or ask you") {
                                RowAction(text: "Unblock") { run(p.userId) { try await store.block(p.userId, false) } }
                            }
                        }
                    }
                } else {
                    Notice("Loading…")
                }
            }
        }
        .task {
            await store.load()
            if let people = try? await store.search("") {
                together = Dictionary(people.compactMap { p in p.sharedEvents.map { (p.userId, $0) } }, uniquingKeysWith: { a, _ in a })
            }
        }
        .refreshable { await store.load() }
    }

    /// A long press that opened a menu also lifts the finger on the row: don't open the profile then.
    private func open(_ p: Person) {
        if T1Overlays.shared.menu == nil { path.append(.social(.profile(p.userId))) }
    }

    private func row(_ p: Person, _ relation: Relation, detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        Button { open(p) } label: {
            ListRow(title: p.displayName, detail: busy == p.userId ? "Working…" : detail, avatar: AvatarView(name: p.displayName, userId: p.userId)) {
                trailing()
            }
        }
        .buttonStyle(.plain)
        .personMenu { PersonActions.menu(p, relation, from: relation == .incoming ? "request" : "friends") }
    }

    private func run(_ id: String, _ work: @escaping () async throws -> Void) {
        busy = id
        Task {
            defer { busy = nil }
            do { try await work() } catch where !error.isCancellation { store.error = error.localizedDescription } catch {}
        }
    }

    private func add() {
        T1Overlays.shared.present(full: true) { FriendAddPanel().screen("friend_add") }
    }
}

/// Add a friend: people you've played with first; a name also finds public profiles; email reaches existing accounts
/// and never says whether one exists.
struct FriendAddPanel: View {
    private var store: FriendsStore { FriendsStore.shared }
    @State private var query = ""
    @State private var people: [Person]?
    @State private var email = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: "Add a friend", subtitle: "They accept to become friends") {
                BarButton("Done") { T1Overlays.shared.dismissPanel() }
            }
            T1SearchField(text: $query, prompt: "Name or handle")
            HairlineList {
                if let error { Notice(error, error: true) }
                if let notice { Notice(notice) }
                Section1(query.isEmpty ? "Played with you" : "Matches")
                if let people {
                    if people.isEmpty {
                        Notice(query.isEmpty ? "People you play events with show up here. Until then, add a friend by email below."
                                             : "No one you've played with or with a public profile matches \"\(query)\".")
                    }
                    ForEach(people) { p in
                        ListRow(title: p.displayName,
                                detail: [p.handle.map { "@\($0)" }, (p.sharedEvents ?? 0) > 0 ? plural(p.sharedEvents ?? 0, "event") + " together" : "Public profile"]
                                    .compactMap { $0 }.joined(separator: " · "),
                                avatar: AvatarView(name: p.displayName, userId: p.userId)) {
                            action(p)
                        }
                        .contentShape(Rectangle())
                        .opensProfile(p.userId, from: "friend_search")
                        .personMenu { PersonActions.menu(p, p.relation ?? .none, from: "search") { Task { await load() } } }
                    }
                } else {
                    Notice("Loading…")
                }
                Section1("By email")
                HStack(spacing: 1) {
                    TextField("", text: $email, prompt: Text("name@example.com").foregroundStyle(T1.muted))
                        .font(T1.mono(15)).tint(T1.accent)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
                    Button { sendEmail() } label: {
                        LabelText("Ask", color: emailValid ? T1.ink : T1.muted)
                            .padding(.horizontal, 20).padding(.vertical, 16)
                            .background(emailValid ? T1.accent : T1.surface)
                    }
                    .buttonStyle(.plain)
                    .disabled(!emailValid || busy)
                }
                Notice("Works for people who already have a Table 1 account.")
            }
        }
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    @ViewBuilder private func action(_ p: Person) -> some View {
        switch p.relation ?? .none {
        case .friend: LabelText("Friends", color: T1.accent)
        case .requested: LabelText("Requested")
        case .incoming: RowAction(text: "Accept", accent: true) { ask(p) }
        case .blocked, .me: EmptyView()
        case .none: RowAction(text: "Add", accent: true) { ask(p) }
        }
    }

    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.count > 5 && e.contains("@") && e.split(separator: "@").last?.contains(".") == true
    }

    private func load() async {
        do {
            people = try await store.search(query)
            error = nil
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
            if people == nil { people = [] }
        }
    }

    private func ask(_ p: Person) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let status = try await store.request(p.userId, via: query.isEmpty ? "played_with" : "search")
                notice = status == "friends" ? "You and \(p.displayName) are friends." : "Asked \(p.displayName)."
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func sendEmail() {
        busy = true
        let address = email.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                try await store.requestByEmail(address)
                email = ""
                notice = "If \(address) has a Table 1 account, they'll get your request."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: profile

struct ProfileScreen: View {
    let userId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }
    @State private var data: ProfileData?
    @State private var match: TradeMatch?
    @State private var busy = false
    @State private var error: String?
    /// Your own profile as: 3 you, 1 a friend, 0 anyone (contract § UX rules 5).
    @State private var viewAs = 3

    var body: some View {
        T1Screen {
            Bar(title: data?.displayName ?? "Profile", subtitle: subtitle, back: { dismiss() }) {
                if let data, data.relation != .me { BarButton("More") { menu(data) } }
            }
            HairlineList {
                if let error { Notice(error, error: true) }
                if let data {
                    if data.relation == .me {
                        T1Segmented(options: [(3, "You"), (1, "A friend"), (0, "Anyone")], selection: Binding(get: { viewAs }, set: { v in
                            viewAs = v
                            if v < 3 { Telemetry.capture("profile_view_as", ["as": v == 1 ? "friend" : "anyone"]) }
                        }))
                    }
                    let shown = displayed(data)
                    header(shown)
                    relationActions(shown)
                    sections(shown)
                } else if error == nil {
                    Notice("Loading…")
                }
            }
        }
        .task {
            await load()
            if data?.relation == .me, store.sharing == nil { await store.loadSharing() }
        }
        .refreshable { await load() }
    }

    /// What this screen shows: your profile as you picked to view it, anyone else's as it came back.
    private func displayed(_ d: ProfileData) -> ProfileData {
        guard d.relation == .me, viewAs < 3, let s = store.sharing else { return d }
        return SharingRules.viewAs(d, s, level: viewAs)
    }

    /// Viewing your own profile as someone else.
    private var asOther: Bool { data?.relation == .me && viewAs < 3 }

    private var subtitle: String? {
        guard let data else { return nil }
        switch data.relation {
        case .me: return "You"
        case .friend: return "Friend"
        case .requested: return "Requested"
        case .incoming: return "Wants to be friends"
        case .blocked: return "Blocked"
        case .none: return data.handle.map { "@\($0)" } ?? "Profile"
        }
    }

    private var person: Person? { data?.person }

    private func header(_ d: ProfileData) -> some View {
        VStack(spacing: 8) {
            AvatarView(name: d.displayName, userId: d.userId, size: 64)
            Text(d.displayName).font(T1.mono(17))
            if let h = d.handle { LabelText("@\(h)") }
            if let r = d.sections.record {
                Text("\(r.matchWins)-\(r.matchLosses)\(r.matchDraws > 0 ? "-\(r.matchDraws)" : "")")
                    .font(T1.mono(36)).tracking(3).foregroundStyle(T1.accent).padding(.top, 8)
                LabelText("\(plural(r.matchWins + r.matchLosses + r.matchDraws, "match", "matches")) · \(plural(r.eventsPlayed, "event"))")
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24).background(T1.surface)
    }

    @ViewBuilder private func relationActions(_ d: ProfileData) -> some View {
        switch asOther ? .me : d.relation {
        case .none: Ghost(text: busy ? "Working…" : "Add friend", accent: true) { run { try await store.request(userId, via: "profile") } }
        case .requested: Ghost(text: busy ? "Working…" : "Requested · Cancel") { run { try await store.remove(userId) } }
        case .incoming:
            HStack(spacing: 1) {
                Ghost(text: "Accept", accent: true) { run { try await store.respond(userId, accept: true) } }
                Ghost(text: "Ignore") { run { try await store.respond(userId, accept: false) } }
            }
        case .blocked: Ghost(text: "Unblock") { run { try await store.block(userId, false) } }
        case .friend, .me: EmptyView()
        }
    }

    @ViewBuilder private func sections(_ d: ProfileData) -> some View {
        let s = d.sections
        if asOther {
            Notice(viewAs == 1 ? "This is what a friend sees." : "This is what anyone on Table 1 sees.")
        } else if d.relation == .me {
            Notice("You see everything here. Switch to A friend or Anyone to see what they see.")
        }
        if data?.relation == .me {
            Button { path.append(.social(.sharing)) } label: { ListRow(title: "Sharing", detail: "Choose who sees each part") }.buttonStyle(.plain)
        }
        if let match, d.relation != .me {
            Section1("Trade matches")
            Button { path.append(.social(.match(userId))) } label: {
                ListRow(title: match.short, detail: "The cards, and Start a trade") {
                    if match.haveUsd + match.wantUsd > 0, let v = PriceBook.text(match.haveUsd + match.wantUsd) { Text(v).font(T1.mono(15)).monospacedDigit() }
                }
            }.buttonStyle(.plain)
        }
        if !d.visible {
            Notice(asOther ? "Only your friends can see your profile. Anyone else sees your name and photo."
                   : d.relation == .blocked ? "You blocked \(d.displayName)." : "Only \(d.displayName)'s friends can see their profile.")
        } else if d.sectionCount == 0 && d.relation != .me {
            Notice("Nothing shared yet.")
        }
        if s.allCards != nil || s.forTrade != nil || s.wants != nil { Section1("Library") }
        if let c = s.allCards {
            // The collection's value shows only on your own profile.
            let value = d.valueUsd.flatMap { PriceBook.text($0) }
            open("All cards", detail: [plural(c.cards, "card"), value].compactMap { $0 }.joined(separator: " · "), kind: "all_cards")
        }
        if let c = s.forTrade { open("For trade", detail: plural(c.cards, "card"), kind: "for_trade") }
        if let c = s.wants { open("Wants", detail: plural(c.cards, "card") + " wanted", kind: "wants") }
        if let b = s.binders, !b.isEmpty {
            Section1("Binders · \(b.count)")
            ForEach(b) { x in open(x.name, detail: [plural(x.cards, "card"), x.forTrade ? "For trade" : nil].compactMap { $0 }.joined(separator: " · "), kind: "binder", id: x.id) }
        }
        if let l = s.decks, !l.isEmpty {
            Section1("Decks · \(l.count)")
            ForEach(l) { x in open(x.name, detail: "\(x.format) · \(plural(x.cards, "card"))", kind: "deck", id: x.id, list: shared(d, x)) }
        }
        if let l = s.cubes, !l.isEmpty {
            Section1("Cubes · \(l.count)")
            ForEach(l) { x in open(x.name, detail: plural(x.cards, "card"), kind: "cube", id: x.id, list: shared(d, x)) }
        }
    }

    private func shared(_ d: ProfileData, _ x: ProfileData.ListSummary) -> SharedList {
        SharedList(format: x.format, owner: d.relation == .me ? nil : d.displayName)
    }

    private func open(_ title: String, detail: String, kind: String, id: String? = nil, list: SharedList? = nil) -> some View {
        Button {
            Telemetry.capture("profile_section_opened", ["section": kind])
            path.append(.social(.profileCards(userId, kind, id, title, list)))
        } label: { ListRow(title: title, detail: detail) }
        .buttonStyle(.plain)
    }

    private func menu(_ d: ProfileData) {
        PersonActions.menu(d.person, d.relation, from: "profile") { Task { await load() } }
    }

    private func load() async {
        do {
            let d = try await store.profile(userId)
            if data == nil { Telemetry.capture("profile_viewed", ["relation": d.relation.rawValue, "sections": d.sectionCount]) }
            data = d
            error = nil
            if d.relation != .me && d.visible { match = try? await store.match(with: userId) }
        } catch where !error.isCancellation {
            self.error = FriendsStore.message(error)
        } catch {}
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work(); await load() } catch { self.error = FriendsStore.message(error) }
        }
    }
}

/// The cards behind one shared section: read-only, in the View you pick (list, grid or stacks, like your own);
/// tap opens the card (your own copies of it). Decks and cubes group by section and type (cubes by color), like your
/// own, and add Export and Copy to my Library.
struct ProfileCardsView: View {
    let userId: String
    let section: ProfileSection
    let title: String
    /// A deck or cube: Export and Copy to my Library.
    var list: SharedList?
    /// Opened from a share link: its cards come through the link, not the profile.
    var token: String?
    /// "Shared by Ana Lind" on a link.
    var byline: String?
    /// A link you made: no Follow row.
    var mine = false
    /// Cards already in hand (an Insights example list): nothing to fetch.
    var preset: [ProfileCard]?
    /// Rows above Export, for whoever opened it (Insights' Add to my decks).
    var actions: AnyView?
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var rows: [ProfileCard]?
    /// Binders, all cards, for trade, wants: one group per card.
    @State private var groups: [CardGroup] = []
    /// Decks and cubes: one line per card, board and finish.
    @State private var lines: [ListLine] = []
    @State private var query = ""
    @State private var error: String?
    @State private var printings = PrintingsDisclosure()
    @State private var keys: [String: GroupKeys] = [:]
    @AppStorage("library.shared.layout") private var layout = CardLayout.list.rawValue
    /// Decks and cubes share Group by with your own; everything else has its own (None to start).
    @AppStorage("library.deck.grouping") private var deckGrouping = CardGrouping.type.rawValue
    @AppStorage("library.cube.grouping") private var cubeGrouping = CardGrouping.color.rawValue
    @AppStorage("library.shared.grouping") private var cardsGrouping = CardGrouping.none.rawValue
    /// Sort the same way: decks and cubes with your own, everything else its own (all start on Name).
    @AppStorage("library.deck.sort") private var deckSort = CardSort.name.rawValue
    @AppStorage("library.cube.sort") private var cubeSort = CardSort.name.rawValue
    @AppStorage("library.shared.sort") private var cardsSort = CardSort.name.rawValue

    private var kind: CardList.Kind? { SharedList.kind(section.kind) }

    /// Someone else's binder, deck or cube (contract/follows-2026-10-25.md).
    private var followable: Bool {
        guard ["binder", "deck", "cube"].contains(section.kind), !mine, Repo.userId != nil || FollowsStore.shared.isDemo else { return false }
        return token != nil || (userId != Repo.userId && !FollowsStore.shared.isMe(userId))
    }

    private var sortBinding: Binding<String> {
        switch kind { case .deck: $deckSort; case .cube: $cubeSort; case nil: $cardsSort }
    }
    private var sort: CardSort { CardSort.of(sortBinding.wrappedValue, kind == nil ? .shared : .list) }

    private var groupingBinding: Binding<String> {
        switch kind { case .deck: $deckGrouping; case .cube: $cubeGrouping; case nil: $cardsGrouping }
    }
    private var grouping: CardGrouping {
        CardGrouping(rawValue: groupingBinding.wrappedValue) ?? (kind == .deck ? .type : kind == .cube ? .color : .none)
    }

    var body: some View {
        // A deck's count leaves out Considering, like the profile's.
        let copies = rows?.filter { kind != .deck || $0.board != "maybe" }.reduce(0) { $0 + $1.qty } ?? 0
        T1Screen {
            Bar(title: title, subtitle: rows == nil ? nil : plural(copies, "card"), back: { dismiss() }) {
                BarButton("View") {
                    CardLayout.menu($layout, screen: "profile_\(section.kind)", printings: $printings, grouping: groupingBinding, list: kind != nil,
                                    sort: sortBinding, sorts: kind == nil ? .shared : .list)
                }
            }
            CatalogStatusRow(catalog: catalog)
            T1SearchField(text: $query, prompt: "Name or type")
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if let error { Notice(error, error: true) }
                        if let byline, query.isEmpty { Notice(byline) }
                        if rows?.isEmpty == true { Notice("Nothing here.") }
                        if followable, query.isEmpty, let id = section.id {
                            FollowRows(kind: section.kind, id: id, title: title, owner: list?.owner, token: token, path: $path)
                        }
                        if let actions, query.isEmpty { actions }
                        if let list, let kind, let rows, !rows.isEmpty, query.isEmpty { listActions(list, kind, rows) }
                        if let kind { listBody(kind, width: geo.size.width) } else { cardsBody(width: geo.size.width) }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .searchUsed(query, screen: "profile_cards")
        .task {
            do {
                if let preset { rows = preset }
                else if let token { rows = try await FriendsStore.shared.sharedCards(token, part: section.kind) }
                else { rows = try await FriendsStore.shared.cards(userId, section) }
            } catch { if !error.isCancellation { self.error = FriendsStore.message(error); rows = [] } }
        }
        .task(id: "\(rows?.count ?? -1)-\(catalog.generation)") {
            catalog.load(userInitiated: true)
            guard let rows, let db = catalog.db else { return }
            if let kind {
                let entries = SharedList.entries(rows)
                lines = await Task.detached(priority: .userInitiated) { ListLine.resolve(entries, kind: kind, db).sorted { $0.name < $1.name } }.value
            } else {
                (groups, keys) = await Task.detached(priority: .userInitiated) { () -> ([CardGroup], [String: GroupKeys]) in
                    let g = Self.build(rows, db)
                    return (g, CardGroup.keys(g, db))
                }.value
            }
        }
    }

    // MARK: decks and cubes

    @ViewBuilder private func listBody(_ kind: CardList.Kind, width: CGFloat) -> some View {
        let all = sort.apply(ListLine.regrouped(lines, by: grouping)) { SortKey(name: $0.name, keys: $0.keys, printing: $0.printing) }
        let shown = query.isEmpty ? all : all.filter { CardSearch.matches(query, name: $0.name, type: $0.type) }
        if shown.isEmpty && !lines.isEmpty { ListRow(title: "No cards match") }
        ForEach(CardList.boardOrder.filter { b in shown.contains { $0.board == b } }, id: \.self) { board in
            let inBoard = shown.filter { $0.board == board }
            BoardHeader(title: Self.boardTitle(board, kind), count: inBoard.reduce(0) { $0 + $1.qty })
            let types = ListLine.groups(inBoard, by: grouping)
            if layout == CardLayout.stacks.rawValue {
                StackRows(stacks: types.map { g in
                    let inGroup = inBoard.filter { $0.group == g }
                    return (id: "s|\(board)|\(g)|\(printings.all)", title: Optional("\(grouping.label(g)) · \(inGroup.reduce(0) { $0 + $1.qty })"), cards: tiles(inGroup))
                }, width: ((width - 1) / 2).rounded(.down))
            } else {
                ForEach(types, id: \.self) { g in
                    let inGroup = inBoard.filter { $0.group == g }
                    Section1("\(grouping.label(g)) · \(inGroup.reduce(0) { $0 + $1.qty })").id("h|\(board)|\(g)")
                    if layout == CardLayout.grid.rawValue {
                        grid(tiles(inGroup), width: width).id("g|\(board)|\(g)|\(printings.all)")
                    } else {
                        ForEach(LineGroup.of(inGroup)) { cg in lineRows(cg) }
                    }
                }
            }
        }
    }

    /// One card's lines in a section: a row, with its printings under a chevron when there are several.
    @ViewBuilder private func lineRows(_ cg: LineGroup) -> some View {
        let open = printings.open(cg.id) && cg.lines.count > 1
        HStack(spacing: 1) {
            Button { openCard(cg.lead.oracleId) } label: {
                CardRow(printing: cg.lead.printing, title: cg.lead.name, detail: cg.lead.type, finish: cg.lead.finish) {
                    Text("\(cg.qty)").font(T1.mono(17)).monospacedDigit()
                }
            }.buttonStyle(.plain)
            if cg.lines.count > 1 { PrintingsChevron(open: open) { printings.toggle(cg.id) } }
        }
        .fixedSize(horizontal: false, vertical: true)
        if open {
            ForEach(cg.lines) { l in
                Button { openCard(l.oracleId) } label: {
                    CardRow(printing: l.printing, title: [l.printing?.setLabel, l.finishLabel].compactMap { $0 }.joined(separator: " · "),
                            detail: nil, finish: l.finish) {
                        Text("\(l.qty)").font(T1.mono(15)).monospacedDigit().foregroundStyle(T1.muted)
                    }
                    .padding(.leading, 24).background(T1.surface)
                }.buttonStyle(.plain)
            }
        }
    }

    private func tiles(_ lines: [ListLine]) -> [StackCard] {
        LineGroup.of(lines).flatMap { cg -> [StackCard] in
            let open = { openCard(cg.lead.oracleId) }
            guard printings.all, cg.lines.count > 1 else {
                return [StackCard(id: cg.id, printing: cg.lead.printing, name: cg.lead.name, qty: cg.qty, finish: cg.lead.finish, open: open)]
            }
            return cg.lines.map { l in StackCard(id: l.id, printing: l.printing, name: l.name, qty: l.qty, finish: l.finish, open: open) }
        }
    }

    // MARK: binders, all cards, for trade, wants

    @ViewBuilder private func cardsBody(width: CGFloat) -> some View {
        let shown = sort.apply(query.isEmpty ? groups : groups.filter { CardSearch.matches(query, name: $0.name, type: $0.type) }) {
            SortKey(name: $0.name, keys: keys[$0.id], printing: $0.cover)
        }
        if shown.isEmpty && !groups.isEmpty { ListRow(title: "No cards match") }
        let sections = CardGroup.sections(shown, by: grouping, keys: keys)
        if layout == CardLayout.stacks.rawValue {
            // Grouped: one stack per group; None: stacks of ten.
            let stacks = sections.flatMap { sec -> [(id: String, title: String?, cards: [StackCard])] in
                let cards = groupTiles(sec.cards)
                if grouping != .none {
                    return [("st|\(sec.key)|\(printings.all)", "\(grouping.label(sec.key)) · \(sec.cards.reduce(0) { $0 + $1.qty })", cards)]
                }
                return stride(from: 0, to: cards.count, by: 10).map { i in ("st|\(printings.all)|\(i)", nil, Array(cards[i..<min(i + 10, cards.count)])) }
            }
            StackRows(stacks: stacks, width: ((width - 1) / 2).rounded(.down))
        } else {
            ForEach(sections, id: \.key) { sec in
                if grouping != .none { Section1("\(grouping.label(sec.key)) · \(sec.cards.reduce(0) { $0 + $1.qty })").id("h|\(sec.key)") }
                if layout == CardLayout.grid.rawValue {
                    grid(groupTiles(sec.cards), width: width).id("grid|\(sec.key)|\(printings.all)")
                } else {
                    ForEach(sec.cards) { g in
                        CardGroupRows(group: g, detail: g.type, open: printings.open(g.id), toggle: { printings.toggle(g.id) },
                                      tap: { _ in if g.known { path.append(.cardIn(g.id, .search)) } })
                    }
                }
            }
        }
    }

    private func groupTiles(_ shown: [CardGroup]) -> [StackCard] {
        shown.flatMap { g -> [StackCard] in
            let open = { if g.known { path.append(.cardIn(g.id, .search)) } }
            guard printings.all, g.parts.count > 1 else {
                return [StackCard(id: g.id, printing: g.cover, name: g.name, qty: g.qty, finish: g.coverFinish, open: open)]
            }
            return g.parts.map { p in StackCard(id: "\(g.id)|\(p.id)", printing: p.printing, name: g.name, qty: p.qty, finish: p.finish, open: open) }
        }
    }

    private func grid(_ cards: [StackCard], width: CGFloat) -> some View {
        let w = ((width - 2) / 3).rounded(.down)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: 1), count: 3), spacing: 1) {
            ForEach(cards) { c in
                Button(action: c.open) { CardTile(printing: c.printing, name: c.name, qty: c.qty, width: w, finish: c.finish) }.buttonStyle(.plain)
            }
        }
    }

    private func openCard(_ oracleId: String?) {
        if let oracleId { path.append(.cardIn(oracleId, .search)) }
    }

    // MARK: export and copy

    /// A deck or cube shared with you: export it like your own, or copy it into your Library as a new list.
    @ViewBuilder private func listActions(_ list: SharedList, _ kind: CardList.Kind, _ rows: [ProfileCard]) -> some View {
        let entries = SharedList.entries(rows)
        Button {
            T1Overlays.shared.present(full: true) {
                ListExportPanel(name: title, kind: kind, entries: entries, from: "profile").screen("list_export")
            }
        } label: {
            ListRow(title: "Export", detail: kind == .deck ? "Text, Arena, MTGO, download or copy" : "Text, Cube Cobra, download or copy")
        }.buttonStyle(.plain)
        if kind == .deck {
            Button {
                T1Overlays.shared.present(full: true) {
                    DeckImagePanel(name: title, format: list.format, entries: entries, owner: list.owner, from: "profile").screen("deck_image")
                }
            } label: {
                ListRow(title: "Deck image", detail: "The cards as a picture, to save or share")
            }.buttonStyle(.plain)
        }
        if let id = section.id, preset == nil {
            SpiceRow(listId: id, token: token, kind: kind, format: list.format, title: title,
                     demo: lines.compactMap { l in
                         l.oracleId.map { SpiceDemoCard(oracleId: $0, name: l.name, qty: l.qty, board: l.board,
                                                        basic: SpiceDemoCard.basics.contains(l.name)) }
                     }, path: $path)
        }
        // Through a link you can rank a cube once you follow it (contract/owned-by-card-2026-10-31.md § 3); the row
        // shows the moment Follow succeeds.
        if kind == .cube, let id = section.id, preset == nil, token == nil || FollowsStore.shared.states[id]?.following == true {
            RankingsRow(listId: id, path: $path)
        }
        if list.owner != nil {
            Button {
                let copy = ListsStore.shared.create(kind: kind, name: title, format: list.format, entries: entries,
                                                    note: list.copyNote(title), from: "profile")
                path.append(.list(copy.id))
            } label: {
                ListRow(title: "Copy to my Library", detail: kind == .deck ? "A new private deck with these cards" : "A new cube with these cards")
            }.buttonStyle(.plain)
        }
    }

    static func boardTitle(_ b: String, _ kind: CardList.Kind) -> String {
        ["commander": "Commander", "main": kind == .deck ? "Main deck" : "Main", "side": "Sideboard", "maybe": "Considering"][b] ?? "Cards"
    }

    /// Groups by card; wants for any printing show the card's cover printing.
    nonisolated static func build(_ rows: [ProfileCard], _ db: CatalogDB) -> [CardGroup] {
        let oracles = rows.filter { $0.cardId == nil }.compactMap(\.oracleId).compactMap { db.oracle(id: $0) }
        let covers = db.covers(oracleIdxs: oracles.map(\.idx))
        let coverOf = Dictionary(oracles.map { ($0.oracleId, covers[$0.idx]?.cardId) }, uniquingKeysWith: { a, _ in a })
        let items = rows.compactMap { r -> CollectionItem? in
            guard let card = r.cardId ?? r.oracleId.flatMap({ coverOf[$0] ?? nil }) else { return nil }
            return CollectionItem(cardId: card, finish: r.finish ?? "nonfoil", condition: r.condition ?? "NM", lang: r.lang ?? "en", qty: r.qty, seq: 0)
        }
        return CardGroup.build(items, db).sorted { $0.norm < $1.norm }
    }
}

// MARK: sharing

struct SharingView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }

    var body: some View {
        T1Screen {
            Bar(title: "Sharing", subtitle: store.sharing.map(SharingRules.summary), back: { dismiss() })
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                if let s = store.sharing {
                    Notice(SharingRules.seesLine(s, level: 1))
                    Notice(SharingRules.seesLine(s, level: 0))
                    if let me = Repo.userId ?? demoUserId {
                        Button { path.append(.social(.profile(me))) } label: {
                            ListRow(title: "View your profile as…", detail: "A friend, or anyone on Table 1")
                        }.buttonStyle(.plain)
                    }
                    Notice("Everything starts private, and new decks stay private until you share them. Your profile caps the rest.")
                    part(.profile, s)
                    part(.record, s)
                    Section1("Library")
                    part(.library, s)
                    ForEach(SharePart.libraryParts, id: \.self) { p in
                        part(p, s)
                        if let kind = ["binders": "binder", "decks": "deck", "cubes": "cube"][p.rawValue] {
                            let items = s.items.filter { $0.kind == kind }
                            if !items.isEmpty {
                                Button { path.append(.social(.sharingItems(kind))) } label: {
                                    let own = items.filter { $0.visibility != nil }.count
                                    ListRow(title: "Each \(kind)", detail: "\(plural(items.count, kind)) · \(own == 0 ? "all \(SharingRules.effective(s, p).label.lowercased())" : "\(own) with their own setting")") {
                                        LabelText("Open", color: T1.text)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Notice("Loading…")
                }
            }
        }
        .task { await store.loadSharing() }
    }

    private func part(_ p: SharePart, _ s: SharingSettings) -> some View {
        SharingControl(title: p.label, detail: p.detail, own: s.own(p), inherits: p.inherits,
                       parent: p == .profile || p == .library || p == .record ? nil : ("Library", s.library),
                       settings: s, isProfile: p == .profile, effect: effect(p)) { v in
            store.change(p, v)
        }
    }

    private var demoUserId: String? {
        #if DEBUG
        store.demo != nil ? FriendsDemoBackend.me : nil
        #else
        nil
        #endif
    }

    /// What the part shows, for the line under its control.
    private func effect(_ p: SharePart) -> String {
        switch p {
        case .profile: "your profile and what reaches them"
        case .library, .binders, .decks, .cubes: "what follows this"
        case .allCards: "every card you own"
        case .forTrade: "your for-trade copies"
        case .wants: "your wants, without max prices"
        case .record: "your lifetime record"
        }
    }
}

/// One part's row and its Private / Friends / Anyone control ("Same" first when it can follow the level above).
struct SharingControl: View {
    /// "Friends see every card you own." / "Only you see it."
    static func effectLine(_ reach: Visibility, _ what: String) -> String {
        switch reach {
        case .private: "Only you see \(what)."
        case .friends: "Friends see \(what)."
        case .public: "Anyone on Table 1 sees \(what)."
        }
    }

    let title: String
    let detail: String
    let own: Visibility?
    let inherits: Bool
    let parent: (name: String, value: Visibility)?
    let settings: SharingSettings
    var isProfile = false
    /// "every card in this binder": what reaches them, for the line under the control.
    var effect: String = "it"
    let set: (Visibility?) -> Void

    private enum Choice: Hashable { case same, v(Visibility) }

    var body: some View {
        let effective = own ?? parent?.value ?? .private
        let capped = !isProfile && SharingRules.capped(settings, effective)
        VStack(spacing: 1) {
            ListRow(title: title, detail: detail) {
                LabelText(effective.label, color: effective == .private ? T1.muted : T1.accent)
            }
            let options: [(value: Choice, label: String)] = (inherits ? [(Choice.same, "Same")] : [])
                + Visibility.allCases.map { (Choice.v($0), $0.label) }
            T1Segmented(options: options, selection: Binding(
                get: { own.map { .v($0) } ?? .same },
                set: { c in if case .v(let v) = c { set(v) } else { set(nil) } }
            ))
            if own == nil, let parent {
                Notice("Same as \(parent.name) · \(parent.value.label).")
            }
            if capped {
                Notice("Set to \(effective.label), but only \(SharingRules.reach(settings, effective) == .friends ? "friends see it" : "you see it"): your profile is \(settings.profile.label).")
            } else {
                Notice(SharingControl.effectLine(isProfile ? settings.profile : SharingRules.reach(settings, effective), effect))
            }
        }
    }
}

struct SharingItemsView: View {
    let kind: String
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }

    var body: some View {
        let group: SharePart = kind == "binder" ? .binders : kind == "cube" ? .cubes : .decks
        T1Screen {
            Bar(title: group.label, subtitle: "Sharing", back: { dismiss() })
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                if let s = store.sharing {
                    ForEach(s.items.filter { $0.kind == kind }) { item in
                        let linkOn = store.link(.item(kind: kind, id: item.id, name: item.name)) != nil
                        SharingControl(title: item.name, detail: (item.forTrade == true ? "For trade" : kind.capitalized) + (linkOn ? " · Link on" : ""),
                                       own: item.visibility, inherits: true, parent: (group.label, SharingRules.effective(s, group)),
                                       settings: s, effect: WhoSeesRow.effect(kind)) { v in
                            store.change(item, v)
                        }
                    }
                }
            }
        }
        .task { if store.sharing == nil { await store.loadSharing() } }
    }
}

// MARK: matches

struct TradeMatchesView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }
    /// Sharing is loaded, so the offer row can decide.
    @State private var offered = false

    var body: some View {
        let m = store.matches
        T1Screen {
            Bar(title: "Trade matches", subtitle: m.map { plural($0.count, "person", "people") }, back: { dismiss() })
            HairlineList {
                if let error = store.error { Notice(error, error: true) }
                Notice("Your wants against friends' for-trade cards, and theirs against yours. People you've played with count when they share publicly.")
                if let s = store.sharing, !SharingOffer.matches.answered, offered,
                   SharingRules.reachOf(s, .forTrade) == .private, SharingRules.reachOf(s, .wants) == .private {
                    Button {
                        SharingOffer.matches.ask("Share For trade and Wants with friends?",
                                                 message: "Friends can see your for-trade copies and your wants (never your max prices), so their matches can find you.",
                                                 parts: [.forTrade, .wants])
                    } label: {
                        ListRow(title: "Share For trade and Wants with friends", detail: "So friends' matches can find you too") {
                            LabelText("Share", color: T1.accent)
                        }
                    }.buttonStyle(.plain)
                }
                if let m {
                    if m.isEmpty {
                        Notice("No matches yet. Matches show once friends share For trade or Wants, and you have wants or a for-trade binder.")
                        Button { path.append(.social(.friends)) } label: { ListRow(title: "Friends", detail: "Add friends to trade with") }.buttonStyle(.plain)
                        Button { path.append(.social(.sharing)) } label: { ListRow(title: "Sharing", detail: "Share your For trade and Wants") }.buttonStyle(.plain)
                    }
                    ForEach(m) { TradeMatchRow(match: $0, path: $path) }
                } else {
                    Notice("Looking…")
                }
            }
        }
        .task {
            if store.sharing == nil { await store.loadSharing() }
            offered = true
            await store.loadMatches()
            if let m = store.matches {
                Telemetry.capture("trade_matches_viewed", ["people": m.count, "have": m.reduce(0) { $0 + $1.haveCopies },
                                                           "want": m.reduce(0) { $0 + $1.wantCopies }])
            }
        }
        .refreshable { await store.loadMatches() }
    }
}

/// One person in Trade matches (and in Trades): who, what each side has, and the value.
struct TradeMatchRow: View {
    let match: TradeMatch
    @Binding var path: [LibraryRoute]

    var body: some View {
        let x = match
        Button { if T1Overlays.shared.menu == nil { path.append(.social(.match(x.userId))) } } label: {
            ListRow(title: x.displayName, detail: x.short + (x.friend ? "" : " · played with you"),
                    avatar: AvatarView(name: x.displayName, userId: x.userId, opensFrom: "trade_match")) {
                if x.haveUsd + x.wantUsd > 0, let v = PriceBook.text(x.haveUsd + x.wantUsd) { Text(v).font(T1.mono(15)).monospacedDigit() }
            }
        }
        .buttonStyle(.plain)
        .personMenu { PersonActions.menu(x.person, x.friend ? .friend : .none, from: "trade_match") }
    }
}

/// One person's match: what they have that you want, what they want that you have; Start a trade drafts both.
struct TradeMatchView: View {
    let userId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var match: TradeMatch?
    @State private var loaded = false
    @State private var names: [String: (name: String, printing: CatalogPrinting?, oracleId: String?)] = [:]
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: match?.displayName ?? "Trade match", subtitle: match.map { $0.friend ? "Friend" : "Played with you" }, back: { dismiss() }) {
                HStack(spacing: 20) {
                    BarButton("Profile") { path.append(.social(.profile(userId))) }
                    if let m = match {
                        BarButton("More") {
                            PersonActions.menu(m.person, m.friend ? .friend : .none, from: "trade_match") {
                                if FriendsStore.shared.list?.blocked.contains(where: { $0.userId == userId }) == true { dismiss() }
                            }
                        }
                    }
                }
            }
            HairlineList {
                if let error { Notice(error, error: true) }
                if let m = match {
                    side("They have · \(m.haveCopies) you want", m.theyHave, value: m.haveUsd, have: true)
                    side("They want · \(m.wantCopies) you have", m.theyWant, value: m.wantUsd, have: false)
                } else if loaded {
                    Notice("Nothing matches with them right now.")
                } else {
                    Notice("Looking…")
                }
            }
            if match != nil {
                BigAction(text: "Start a trade", busy: busy, accent: true) { start() }
            }
        }
        .task {
            match = store.matches?.first { $0.userId == userId }
            do { match = try await store.match(with: userId) } catch where !error.isCancellation { self.error = error.localizedDescription } catch {}
            loaded = true
        }
        .task(id: "\(match?.haveCopies ?? -1)-\(match?.wantCopies ?? -1)-\(catalog.generation)") {
            catalog.load(userInitiated: true)
            guard let m = match, let db = catalog.db else { return }
            let ids = Array(Set((m.theyHave + m.theyWant).map(\.cardId)))
            await PriceBook.shared.load(ids)
            let p = db.printings(ids: ids)
            let o = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
            names = Dictionary(uniqueKeysWithValues: ids.map { id in
                let oracle = p[id].flatMap { o[$0.oracleIdx] }
                return (id, (oracle?.name ?? "Card not in local data yet", p[id], oracle?.oracleId))
            })
        }
    }

    @ViewBuilder private func side(_ title: String, _ lines: [MatchLine], value: Double, have: Bool) -> some View {
        Section1(title + (value > 0 ? PriceBook.text(value).map { " · \($0)" } ?? "" : ""))
        if lines.isEmpty { Notice(have ? "Nothing of theirs that you want." : "Nothing of yours that they want.") }
        ForEach(lines) { l in
            let n = names[l.cardId]
            Button { if let o = n?.oracleId { path.append(.cardIn(o, .search)) } } label: {
                CardRow(printing: n?.printing, title: n?.name ?? "…", detail: detail(l, n?.printing, have: have)) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(l.qty)").font(T1.mono(17)).monospacedDigit()
                        if l.overMax == true { LabelText("Over your max", color: T1.danger) }
                        else if let u = PriceBook.text(l.usd ?? PriceBook.shared.usd(l.cardId, l.finish, l.condition)) { LabelText(u) }
                    }
                }
            }.buttonStyle(.plain)
        }
    }

    private func detail(_ l: MatchLine, _ p: CatalogPrinting?, have: Bool) -> String {
        let printing = p.map { "\($0.set.uppercased()) \($0.cn)" }
        let finish = l.finish == "nonfoil" ? nil : l.finish.capitalized
        let want = switch l.want.tier {
        case "exact": have ? "You want this printing and finish" : "Wants this printing and finish"
        case "printing": have ? "You want this printing" : "Wants this printing"
        default: have ? "You want any printing" : "Wants any printing"
        }
        return [printing, finish, l.condition == "NM" ? nil : l.condition, l.lang == "en" ? nil : l.lang.uppercased(), want]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func start() {
        guard let m = match else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let id = try await store.startTrade(m)
                path.append(.trade(id))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: block and report (contract § UX rules 6)

extension FriendsStore {
    /// What the UI says for a failed read: anything hidden or gone reads "This isn't available" (never "That's private").
    static func message(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.contains("That's private") || text.contains("This isn't available") || text.contains("42501") ? "This isn't available." : text
    }
}

/// The menu wherever a person appears: Unfriend / Cancel request / Ignore, Block (or Unblock), Report.
@MainActor
enum PersonActions {
    static func menu(_ p: Person, _ relation: Relation, from: String, changed: (() -> Void)? = nil) {
        let store = FriendsStore.shared
        func run(_ work: @escaping () async throws -> Void) {
            Task {
                do { try await work(); changed?() } catch { store.error = FriendsStore.message(error) }
            }
        }
        var items: [T1MenuItem] = []
        switch relation {
        case .friend:
            items.append(T1MenuItem(title: "Unfriend", detail: "They aren't told") {
                T1Overlays.shared.ask("Unfriend \(p.displayName)?",
                                      message: "You'll stop seeing what each of you shares with friends. They aren't told.",
                                      action: "Unfriend", destructive: true) { run { try await store.remove(p.userId) } }
            })
        case .requested: items.append(T1MenuItem(title: "Cancel request") { run { try await store.remove(p.userId) } })
        case .incoming: items.append(T1MenuItem(title: "Ignore request", detail: "They aren't told") { run { try await store.respond(p.userId, accept: false) } })
        case .blocked, .none, .me: break
        }
        if relation == .blocked {
            items.append(T1MenuItem(title: "Unblock") { run { try await store.block(p.userId, false) } })
        } else if relation != .me {
            items.append(T1MenuItem(title: "Block", detail: "They can't find you or ask you", destructive: true) {
                confirmBlock(p) { run { try await store.block(p.userId, true) } }
            })
        }
        if relation != .me {
            items.append(T1MenuItem(title: "Report", detail: "Tell Table 1 about this account", destructive: true) {
                report(p, from: from, changed: changed)
            })
        }
        T1Overlays.shared.showMenu(p.displayName, items)
    }

    static func confirmBlock(_ p: Person, _ block: @escaping () -> Void) {
        T1Overlays.shared.ask("Block \(p.displayName)?",
                              message: "They won't be able to find you, see your Library or ask to be friends. They won't be told. You'll still both be in any event you're both playing.",
                              action: "Block", destructive: true, onConfirm: block)
    }

    static func report(_ p: Person, from: String, item: (kind: String, id: String, name: String)? = nil, changed: (() -> Void)? = nil) {
        T1Overlays.shared.present(full: true) {
            ReportPanel(person: p, from: from, item: item.map { ReportPanel.Item(kind: $0.kind, id: $0.id, name: $0.name) }, changed: changed)
                .screen("report")
        }
    }
}

extension View {
    /// Long press on a person's row opens their menu (VoiceOver: the "More" action). Rows check
    /// `T1Overlays.shared.menu == nil` before opening, so lifting the finger doesn't also open the row.
    func personMenu(_ open: @escaping () -> Void) -> some View {
        simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in open() })
            .accessibilityAction(named: "More", open)
    }
}

/// Report an account: a reason, an optional note, and Also block them (on for Harassment).
struct ReportPanel: View {
    struct Item { let kind: String; let id: String; let name: String }
    let person: Person
    let from: String
    var item: Item?
    var changed: (() -> Void)?
    @State private var reason: ReportReason?
    @State private var note = ""
    @State private var block = false
    @State private var busy = false
    @State private var sent = false
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: "Report \(person.displayName)", subtitle: item?.name ?? "They won't know you reported them") {
                BarButton(sent ? "Done" : "Cancel") { T1Overlays.shared.dismissPanel() }
            }
            HairlineList {
                if let error { Notice(error, error: true) }
                if sent {
                    Notice("Thanks. We'll look into it. They won't know you reported them.")
                    if block { Notice("You blocked \(person.displayName). Unblock them any time in Friends.") }
                } else {
                    Section1("What's wrong")
                    ForEach(ReportReason.allCases, id: \.self) { r in
                        Button {
                            reason = r
                            block = r.blocksByDefault
                        } label: {
                            ListRow(title: r.label) {
                                if reason == r { LabelText("Picked", color: T1.accent) }
                            }
                        }.buttonStyle(.plain)
                    }
                    Section1("Anything else · optional")
                    TextField("", text: $note, prompt: Text("What happened").foregroundStyle(T1.muted), axis: .vertical)
                        .lineLimit(3...6)
                        .font(T1.mono(15)).tint(T1.accent)
                        .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
                        .onChange(of: note) { _, v in if v.count > 500 { note = String(v.prefix(500)) } }
                    T1Switch(title: "Also block them", detail: "They can't find you or ask you", isOn: $block)
                }
            }
            if !sent {
                BigAction(text: "Send report", enabled: reason != nil, busy: busy, accent: true) { send() }
            }
        }
    }

    private func send() {
        guard let reason else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await FriendsStore.shared.report(person.userId, reason: reason, note: note, from: from,
                                                     item: item.map { ($0.kind, $0.id) }, block: block)
                sent = true
                error = nil
                changed?()
            } catch {
                self.error = FriendsStore.message(error)
            }
        }
    }
}

// MARK: visibility on the thing itself (contract § UX rules 2)

/// "Who sees this" at the top of a deck, cube or binder: the effective value, and a menu to change it.
struct WhoSeesRow: View {
    let kind: String // binder / deck / cube
    let id: String
    let name: String
    var forTrade: Bool?
    private var store: FriendsStore { FriendsStore.shared }

    static func effect(_ kind: String) -> String {
        kind == "binder" ? "every card in this binder, with condition and language" : "every card in this \(kind)"
    }

    var body: some View {
        let s = store.sharing
        let item = store.shareItem(kind: kind, id: id, name: name, forTrade: forTrade)
        let group: SharePart = kind == "binder" ? .binders : kind == "cube" ? .cubes : .decks
        Button { if let s { menu(s, item, group) } } label: {
            if let s {
                let eff = SharingRules.effective(s, item), reach = SharingRules.reachOf(s, item)
                let linkOn = store.link(.item(kind: kind, id: id, name: name)) != nil
                ListRow(title: "Who sees this",
                        detail: (SharingRules.capped(s, eff) ? "Set to \(eff.label), capped by your profile"
                            : item.visibility == nil ? "Same as \(group.label)" : "Its own setting") + (linkOn ? " · Link on" : "")) {
                    LabelText(reach.label, color: reach == .private ? T1.muted : T1.accent)
                }
            } else {
                ListRow(title: "Who sees this", detail: "Loading…")
            }
        }
        .buttonStyle(.plain)
        .task { if store.sharing == nil { await store.loadSharing() } }
    }

    private func menu(_ s: SharingSettings, _ item: ShareItem, _ group: SharePart) {
        let groupValue = SharingRules.effective(s, group)
        var items = [T1MenuItem(title: "Same as \(group.label) · \(groupValue.label)", detail: "Follows Account → Sharing", checked: item.visibility == nil) {
            store.change(item, nil)
        }]
        for v in Visibility.allCases {
            items.append(T1MenuItem(title: v.label, detail: v == .private ? "Only you" : v == .friends ? "Your friends" : "Anyone on Table 1",
                                    checked: item.visibility == v) { store.change(item, v) })
        }
        T1Overlays.shared.showMenu("Who sees \(name)", message: s.profile == .public ? nil : "Your profile is \(s.profile.label), so nothing here goes further than that.", items)
    }
}

// MARK: share (contract/share-links-2026-10-23.md)

/// "Share" on All cards, Wants, Binders (For trade), each binder, deck and cube.
struct ShareRow: View {
    let target: ShareTarget
    /// Telemetry: all_cards / wants / binders / binder / deck / cube.
    let from: String
    @Binding var path: [LibraryRoute]

    var body: some View {
        Button {
            Telemetry.capture("share_opened", ["part": target.part, "from": from])
            path.append(.social(.share(target)))
        } label: {
            ListRow(title: target.part == "for_trade" ? "Share For trade" : "Share", detail: "Link, or who sees it on Table 1") {
                if FriendsStore.shared.link(target) != nil { LabelText("Link on", color: T1.accent) }
            }
        }
        .buttonStyle(.plain)
        .task { if FriendsStore.shared.sharing == nil { await FriendsStore.shared.loadSharing() } }
    }
}

/// One part's Share screen: Anyone with the link, who sees it on Table 1, and (decks and cubes) a copy as text or a picture.
struct ShareView: View {
    let target: ShareTarget
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: FriendsStore { FriendsStore.shared }
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    @State private var share: ShareFile?

    var body: some View {
        T1Screen {
            Bar(title: "Share", subtitle: target.title, back: { dismiss() })
            HairlineList {
                if let error { Notice(error, error: true) }
                Section1("Anyone with the link")
                if let link = store.link(target) {
                    linkRows(link)
                } else {
                    Button { make() } label: {
                        ListRow(title: busy ? "Making a link…" : "Make a link", detail: "Works without an account")
                    }
                    .buttonStyle(.plain).disabled(busy || store.sharing == nil)
                }
                Section1("On Table 1")
                onTable1
                if let list = target.id.flatMap({ ListsStore.shared.list(id: $0) }), target.part == "deck" || target.part == "cube" {
                    Section1("As a copy")
                    Button {
                        T1Overlays.shared.present(full: true) {
                            ListExportPanel(name: list.name, kind: list.kind, entries: list.entries, from: "own").screen("list_export")
                        }
                    } label: {
                        ListRow(title: "Export", detail: list.kind == .deck ? "Text, Arena, MTGO, download or copy" : "Text, Cube Cobra, download or copy")
                    }.buttonStyle(.plain)
                    if list.kind == .deck {
                        Button {
                            T1Overlays.shared.present(full: true) {
                                DeckImagePanel(name: list.name, format: list.format, entries: list.entries, from: "own").screen("deck_image")
                            }
                        } label: {
                            ListRow(title: "Deck image", detail: "The cards as a picture, to save or share")
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $share) { ShareSheet(share: $0).ignoresSafeArea() }
        .task { if store.sharing == nil { await store.loadSharing() } }
    }

    @ViewBuilder private func linkRows(_ link: PartLink) -> some View {
        Notice("Anyone with this link sees \(target.what), even without a Table 1 account. Nothing else on your profile shows.")
        ListRow(title: link.url.absoluteString.replacingOccurrences(of: "https://", with: ""), detail: note ?? "Link on")
        Button {
            share = ShareFile(url: link.url)
            Telemetry.capture("share_link_sent", ["part": target.part, "how": "share"])
        } label: { ListRow(title: "Share link") }.buttonStyle(.plain)
        Button {
            UIPasteboard.general.url = link.url
            note = "Copied"
            Telemetry.capture("share_link_sent", ["part": target.part, "how": "copy"])
        } label: { ListRow(title: "Copy link") }.buttonStyle(.plain)
        Button {
            T1Overlays.shared.ask("Make a new link?", message: "The old link stops working for anyone who has it.", action: "New link") {
                run { try await store.makeLink(target, new: true) }
            }
        } label: { ListRow(title: "New link") }.buttonStyle(.plain).disabled(busy)
        Button {
            T1Overlays.shared.ask("Stop sharing the link?", message: "It stops working for anyone who has it. Who sees this on Table 1 doesn't change.",
                                  action: "Stop sharing", destructive: true) {
                run { try await store.stopLink(target) }
            }
        } label: {
            ListRow(title: "Stop sharing link") { LabelText("Off", color: T1.danger) }
        }.buttonStyle(.plain).disabled(busy)
    }

    /// The part's own setting (the same menu and confirm as everywhere), then its profile address once it reaches someone.
    @ViewBuilder private var onTable1: some View {
        if let s = store.sharing {
            let reach: Visibility = {
                if let p = target.sharePart { return SharingRules.reachOf(s, p) }
                return SharingRules.reachOf(s, store.shareItem(kind: target.part, id: target.id ?? "", name: target.title))
            }()
            if let p = target.sharePart {
                Button { partMenu(s, p) } label: {
                    ListRow(title: "Who sees this", detail: s.own(p) == nil ? "Same as Library" : "Its own setting") {
                        LabelText(reach.label, color: reach == .private ? T1.muted : T1.accent)
                    }
                }.buttonStyle(.plain)
            } else if let id = target.id {
                WhoSeesRow(kind: target.part, id: id, name: target.title, forTrade: target.forTrade)
            }
            if reach == .private {
                Notice("Only you see it on Table 1. A link works without changing that.")
            } else if let me = Repo.userId ?? demoUserId {
                Button {
                    share = ShareFile(url: target.profileURL(me))
                    Telemetry.capture("share_profile_link_sent", ["part": target.part])
                } label: {
                    ListRow(title: "Send profile link", detail: "Only \(reach.who) can open it")
                }.buttonStyle(.plain)
            }
        } else {
            Notice("Loading…")
        }
    }

    private func partMenu(_ s: SharingSettings, _ p: SharePart) {
        var items = [T1MenuItem(title: "Same as Library · \(s.library.label)", detail: "Follows Account → Sharing", checked: s.own(p) == nil) {
            store.change(p, nil)
        }]
        for v in Visibility.allCases {
            items.append(T1MenuItem(title: v.label, detail: v == .private ? "Only you" : v == .friends ? "Your friends" : "Anyone on Table 1",
                                    checked: s.own(p) == v) { store.change(p, v) })
        }
        T1Overlays.shared.showMenu("Who sees \(p.label)", message: s.profile == .public ? nil : "Your profile is \(s.profile.label), so nothing here goes further than that.", items)
    }

    private func make() {
        T1Overlays.shared.ask("Make a link to \(target.title)?", message: target.confirmMessage, action: "Make link") {
            run { try await store.makeLink(target) }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work(); error = nil; note = nil } catch { self.error = FriendsStore.message(error) }
        }
    }

    private var demoUserId: String? {
        #if DEBUG
        store.demo != nil ? FriendsDemoBackend.me : nil
        #else
        nil
        #endif
    }
}

/// table-1.site/l/<token> in the app (signed in): what the link shows, like a profile section.
struct SharedLinkView: View {
    let token: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var data: SharedLinkData?
    @State private var error: String?

    var body: some View {
        if let data {
            ProfileCardsView(userId: "", section: ProfileSection(kind: data.part, id: data.id), title: data.title,
                             list: data.format.map { SharedList(format: $0, owner: data.mine ? nil : data.owner.displayName) },
                             token: token, byline: data.byline, mine: data.mine,
                             path: $path)
        } else {
            T1Screen {
                Bar(title: "Shared", back: { dismiss() })
                HairlineList {
                    if let error {
                        Notice(error, error: true)
                        Notice("The link may have been turned off.")
                    } else {
                        Notice("Loading…")
                    }
                }
            }
            .task {
                do {
                    let d = try await FriendsStore.shared.shared(token)
                    Telemetry.capture("shared_link_opened", ["part": d.part, "signed_in": true, "mine": d.mine])
                    data = d
                } catch where !error.isCancellation {
                    self.error = FriendsStore.message(error)
                } catch {}
            }
        }
    }
}

// MARK: offers (contract § UX rules 8)

/// Account tab, after your first event while Record is private: "Show your record on your profile?"
struct RecordOffer: View {
    let eventsPlayed: Int
    private var store: FriendsStore { FriendsStore.shared }
    @State private var hidden = false

    var body: some View {
        if !hidden, eventsPlayed >= 1, !SharingOffer.record.answered, let s = store.sharing, s.record == .private {
            ListRow(title: "Show your record on your profile?", detail: "Friends would see your wins, losses and draws") {
                HStack(spacing: 1) {
                    RowAction(text: "Friends", accent: true) {
                        SharingOffer.record.answer(true)
                        hidden = true
                        store.change([(.record, .friends)], ask: false)
                    }
                    RowAction(text: "Not now") {
                        SharingOffer.record.answer(false)
                        hidden = true
                    }
                }
            }
        }
    }
}
