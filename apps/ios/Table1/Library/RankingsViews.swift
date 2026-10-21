import Photos
import SwiftUI

/* Cube rankings screens (contract/cube-rankings-2026-10-21.md, "Where"): a Rankings row on each cube, the cube's
   rankings, one ranking's overview (a tile per color and the final), the picking screen, the lists with each card's
   history (why it sits where it does, its screens, redo), comparing two rankings, and the top 100 as a picture. */

private func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String { "\(n.formatted()) \(n == 1 ? one : many ?? one + "s")" }

// MARK: the row on a cube

/// "Rankings" on a cube screen (yours or shared with you), with how many there are and how far yours has got.
struct RankingsRow: View {
    let listId: String
    @Binding var path: [LibraryRoute]
    @State private var detail: String?

    var body: some View {
        Button { path.append(.rankings(listId)) } label: {
            ListRow(title: "Rankings", detail: detail ?? "Stack-rank this cube's cards")
        }
        .buttonStyle(.plain)
        .task {
            guard let r = try? await RankingsStore.shared.rankings(listId: listId) else { return }
            let mine = r.rankings.first(where: \.mine)
            if r.rankings.isEmpty { detail = "Rank this cube's cards" } else {
                detail = [plural(r.rankings.count, "ranking"), mine.map { "yours: \($0.sorted)/\($0.categories) sorted" }]
                    .compactMap { $0 }.joined(separator: " · ")
            }
        }
    }
}

// MARK: a cube's rankings (or all of yours)

struct RankingsView: View {
    /// The cube; nil lists every ranking of yours.
    let listId: String?
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var data: CubeRankings?
    /// Every ranking of yours: other people's cubes you can rank too.
    @State private var others: [RankableCube] = []
    @State private var error: String?
    @State private var creating = false
    @State private var name = "My ranking"
    @State private var depth = "half"
    @State private var top = 100
    @State private var sharing = "cube"
    @State private var busy = false

    var body: some View {
        let cube = data?.cube
        T1Screen {
            Bar(title: "Rankings", subtitle: listId == nil ? "Yours, and cubes you can rank" : cube.map { $0.mine ? $0.name : "\($0.name) · \($0.owner?.displayName ?? "")" },
                back: { dismiss() })
            HairlineList {
                if let error { Notice(error, error: true) }
                if data == nil && error == nil { Notice("Loading rankings…") }
                if let data {
                    if listId != nil {
                        Notice("Sort each color by putting up to four cards in order at a time, then rank the best cards across " +
                               "the whole cube. Everyone who can see this cube can watch and compare the rankings shared with it.")
                    }
                    if data.canRank, let cube { newRanking(cube) }
                    let mine = data.rankings.filter(\.mine), others = data.rankings.filter { !$0.mine }
                    if !mine.isEmpty {
                        if listId != nil { Section1("Yours") }
                        ForEach(mine) { row($0) }
                    }
                    if listId != nil {
                        Section1("Everyone else's")
                        if others.isEmpty { Notice("Nobody else has ranked this cube yet.") }
                        ForEach(others) { row($0) }
                    } else if mine.isEmpty {
                        Notice("No rankings yet. Open one of your cubes and tap Rankings, or rank a friend's cube below.")
                    }
                    if listId == nil { rankable }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            data = try await RankingsStore.shared.rankings(listId: listId)
            if listId == nil { others = try await RankingsStore.shared.rankable() }
            error = nil
        } catch where !error.isCancellation {
            self.error = error.localizedDescription
        } catch {}
    }

    /// Other people's cubes shared with you, to rank in your own ranking.
    @ViewBuilder private var rankable: some View {
        Section1("Cubes you can rank")
        if others.isEmpty {
            Notice("When a friend, or someone you've played with, shares a cube with you, it shows here. You can also open any cube " +
                   "shared with you on someone's profile and tap Rankings.")
        }
        ForEach(others) { c in
            Button { path.append(.rankings(c.id)) } label: {
                ListRow(title: c.name, detail: [c.owner?.displayName, plural(c.cards, "card"), c.rankings == 0 ? "no rankings yet" : plural(c.rankings, "ranking"),
                                                c.mine > 0 ? "\(c.mine) yours" : nil].compactMap { $0 }.joined(separator: " · "),
                        avatar: AvatarView(name: c.owner?.displayName ?? "?", userId: c.owner?.userId, size: 28))
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private func newRanking(_ cube: RankingCube) -> some View {
        if creating {
            Field(label: "Name", text: $name)
            T1Segmented(options: [("half", "Top half"), ("full", "Every card")], selection: $depth)
            Notice(depth == "half" ? "Each color is ordered until its top half is in order; the rest sit below it. About half the screens."
                                   : "Every card of each color is put in order.")
            T1Segmented(options: [(100, "Top 100"), (50, "Top 50")], selection: $top)
            T1Segmented(options: [("cube", "Shared with the cube"), ("private", "Only me")], selection: $sharing)
            Notice(sharing == "cube" ? "Who sees this: everyone who can see \(cube.name)\(cube.mine ? "" : ", including \(cube.owner?.displayName ?? "its owner")")."
                                     : "Who sees this: only you.")
            HStack(spacing: 1) {
                Ghost(text: "Cancel") { creating = false }
                Ghost(text: busy ? "Starting…" : "Start", accent: true) { Task { await create(cube) } }
            }
        } else {
            Button { creating = true } label: {
                ListRow(title: cube.mine ? "New ranking" : cube.owner.map { "Rank \($0.displayName)'s cube" } ?? "Rank this cube",
                    detail: cube.mine ? "Sort each color, then the top 100" : "Your own ranking: each color, then the top 100")
            }.buttonStyle(.plain)
        }
    }

    private func create(_ cube: RankingCube) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await RankingsStore.shared.create(listId: cube.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                          depth: depth, top: top, sharing: sharing, ownCube: cube.mine)
            creating = false
            await load()
            path.append(.ranking(r.id))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func row(_ r: RankingRow) -> some View {
        Button { path.append(.ranking(r.id)) } label: {
            ListRow(title: r.name, detail: [listId == nil ? r.cube?.name : r.mine ? "You" : r.by?.displayName, r.progress]
                        .compactMap { $0 }.joined(separator: " · "),
                    avatar: r.mine ? nil : AvatarView(name: r.by?.displayName ?? "?", userId: r.by?.userId, size: 28)) {
                if let d = r.updatedShort { LabelText(d) }
            }
        }.buttonStyle(.plain)
    }
}

// MARK: one ranking

struct RankingView: View {
    let rankingId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var model: RankingModel { RankingsStore.shared.model(rankingId) }
    @State private var others: [RankingRow] = []
    @State private var newName = ""

    var body: some View {
        let m = model
        T1Screen {
            Bar(title: m.row?.name ?? "Ranking", subtitle: [m.row?.whose, m.cube?.name].compactMap { $0 }.joined(separator: " · "), back: { dismiss() })
            HairlineList {
                if let e = m.error { Notice(e, error: true) }
                if let n = m.notice { Notice(n) }
                if m.cubeGone, m.row != nil { Notice("This cube isn't shared with you any more, so only its lists show.") }
                if let row = m.row, let st = m.state {
                    if !row.mine { Notice("You're watching \(row.by?.displayName ?? "someone")'s ranking. It updates live as they pick.") }
                    if row.depth == "half" { Notice("This ranking orders only the top half of each color.") }
                    ForEach(st.jobs, id: \.self) { tile($0, st, row) }
                    finalTile(st, row)
                    pickTile(row)
                    Button { path.append(.rankingChanges(rankingId)) } label: {
                        ListRow(title: "Changes", detail: m.changes.isEmpty ? "Every move of every card, as it happens" : "\(plural(m.changes.count, "change")) so far")
                    }.buttonStyle(.plain)
                    compareRow(row)
                    Button {
                        T1Overlays.shared.present(full: true) { RankingImagePanel(model: m).screen("ranking_image") }
                    } label: {
                        ListRow(title: "Top \(row.top) image", detail: "The final as a picture, to save or share")
                    }.buttonStyle(.plain)
                    if row.mine { settings(row) }
                } else if m.error == nil {
                    Notice(CatalogStore.shared.db == nil ? "Waiting for the card data…" : "Loading the ranking…")
                }
            }
        }
        .task { await m.load() }
        .task(id: CatalogStore.shared.generation) { if m.state == nil, m.row != nil { await m.load() } }
        .task { await m.watch() }
        .task(id: m.row?.listId) {
            guard let list = m.row?.listId, let r = try? await RankingsStore.shared.rankings(listId: list) else { return }
            others = r.rankings.filter { $0.id != rankingId }
        }
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(T1.bg)
                Rectangle().fill(fraction >= 1 ? T1.accent : T1.text).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 3)
    }

    private func tileFrame<Buttons: View>(_ title: String, _ stateText: String, done: Bool, fraction: Double, note: String,
                                          @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased()).font(T1.mono(15, .semibold)).tracking(1.5)
                Spacer()
                LabelText(stateText, color: done ? T1.accent : T1.muted)
            }
            bar(fraction)
            Text(note).font(T1.mono(12)).foregroundStyle(T1.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 1) { buttons() }
        }
        .padding(16)
        .background(T1.surface)
    }

    private func tile(_ job: RankJob, _ st: RankingState, _ row: RankingRow) -> some View {
        let s = st.session(job)
        let used = st.knowledge.perJob[job.rawValue] ?? 0
        let size = st.size(job)
        let note: String
        if s.done {
            note = s.target < size ? "Top \(s.target) of \(size) sorted in \(plural(used, "screen"))." : "All \(size) sorted in \(plural(used, "screen"))."
        } else if used == 0 {
            note = "\(plural(size, "card")) · about \(plural(st.expected(job), "screen"))"
        } else {
            note = "\(s.top.count) of the top \(s.target) placed · about \(plural(max(1, st.expected(job) - used), "screen")) to go"
        }
        return tileFrame(job.title, s.done ? "Sorted" : used > 0 ? "In progress" : "Not started", done: s.done,
                         fraction: Double(s.top.count) / Double(max(1, s.target)), note: note) {
            if !s.done {
                Ghost(text: row.mine ? (used > 0 ? "Continue" : "Start") : "Watch", accent: row.mine) { path.append(.rankingPick(rankingId, job.rawValue)) }
            }
            Ghost(text: "List") { path.append(.rankingLists(rankingId, job.rawValue)) }
        }
    }

    private func finalTile(_ st: RankingState, _ row: RankingRow) -> some View {
        let s = st.session(.final)
        let used = st.knowledge.perJob["F"] ?? 0
        let unsorted = st.jobs.filter { !st.session($0).done }.count
        let note: String
        if s.done {
            note = "All \(s.target) places ranked in \(plural(used, "screen"))."
        } else {
            var t = "\(s.top.count) of \(s.target) ranked · about \(plural(max(1, st.expected(.final) - used), "screen")) left once every color is sorted."
            if unsorted > 0 {
                t += " \(unsorted == 1 ? "1 color is" : "\(unsorted) colors are") not fully sorted yet; the final works anyway but will also ask about cards inside \(unsorted == 1 ? "it" : "them")."
            }
            note = t
        }
        return tileFrame("Final · Top \(s.target)", s.done ? "Complete" : used > 0 ? "In progress" : "Not started", done: s.done,
                         fraction: Double(s.top.count) / Double(max(1, s.target)), note: note) {
            if !s.done {
                Ghost(text: row.mine ? (used > 0 ? "Continue the final" : "Start the final") : "Watch", accent: row.mine) {
                    path.append(.rankingPick(rankingId, "F"))
                }
            }
            Ghost(text: "Top \(s.target) list") { path.append(.rankingLists(rankingId, "F")) }
        }
    }

    private func pickTile(_ row: RankingRow) -> some View {
        let picks = model.picks
        let disagreed = picks.filter { $0.disagreed > 0 || $0.won }.count
        return tileFrame("P1P1", picks.isEmpty ? "" : plural(picks.count, "pick"), done: false, fraction: 0,
                         note: picks.isEmpty ? "Refine \(row.mine ? "your" : "this") ranking: pick one card from a 15-card pack, like the first pick of a draft."
                                             : "\(plural(picks.count, "pick")) · \(disagreed == 0 ? "all agreed with the ranking" : "\(disagreed) disagreed with the ranking")") {
            Ghost(text: row.mine ? "Open a pack" : "Pick history", accent: row.mine) { path.append(.rankingPack(rankingId)) }
        }
    }

    @ViewBuilder private func compareRow(_ row: RankingRow) -> some View {
        Button {
            if others.isEmpty { return }
            T1Overlays.shared.showMenu("Compare with", others.map { o in
                T1MenuItem(title: "\(o.by?.displayName ?? "Someone") · \(o.name)") { path.append(.rankingCompare(rankingId, o.id, "F")) }
            })
        } label: {
            ListRow(title: "Compare with another ranking…", detail: others.isEmpty ? "No other rankings of this cube yet" : plural(others.count, "other ranking"))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func settings(_ row: RankingRow) -> some View {
        Section1("Settings")
        Field(label: "Name", text: Binding(get: { newName.isEmpty ? row.name : newName }, set: { newName = $0 }))
        if !newName.isEmpty && newName != row.name {
            Ghost(text: "Rename", accent: true) {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await model.update(name: n.isEmpty ? nil : n); newName = "" }
            }
        }
        T1Segmented(options: [("half", "Top half"), ("full", "Every card")],
                    selection: Binding(get: { row.depth }, set: { d in Task { await model.update(depth: d) } }))
        T1Segmented(options: [(100, "Top 100"), (50, "Top 50")],
                    selection: Binding(get: { row.top }, set: { t in Task { await model.update(top: t) } }))
        T1Segmented(options: [("cube", "Shared with the cube"), ("private", "Only me")],
                    selection: Binding(get: { row.sharing }, set: { s in Task { await model.update(sharing: s) } }))
        Button {
            T1Overlays.shared.ask("Delete \(row.name)?", message: "This removes every pick in it, on every device. It can't be undone.",
                                  action: "Yes, delete it", destructive: true) {
                Task {
                    do { try await RankingsStore.shared.delete(rankingId); dismiss() } catch { model.error = error.localizedDescription }
                }
            }
        } label: {
            ListRow(title: "Delete this ranking", detail: "Every pick, on every device")
        }.buttonStyle(.plain)
    }
}

// MARK: the picking screen

struct RankingPickView: View {
    let rankingId: String
    let job: RankJob
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var model: RankingModel { RankingsStore.shared.model(rankingId) }
    /// The cards on screen, spot 1 first.
    @State private var order: [Int] = []
    @State private var pinned: Set<Int> = []
    @State private var picked: Int?
    @State private var dragging: Int?
    @State private var dragStart: CGPoint = .zero
    @State private var dragAt: CGPoint = .zero
    @State private var questionKey = ""

    var body: some View {
        let m = model
        T1Screen {
            Bar(title: job == .final ? "Final" : job.title, subtitle: m.row?.name, back: { dismiss() })
            if let st = m.state, let row = m.row, let q = m.question(job) {
                if let n = m.notice { Notice(n) }
                if let e = m.error { Notice(e, error: true) }
                header(st, q.session, row)
                if q.session.done {
                    done(st, q.session)
                    Spacer()
                } else {
                    if row.mine && !pinned.isEmpty {
                        Notice("Locked cards keep the order you already gave them. Move the free card to where it belongs.")
                    } else if row.mine && !m.log.contains(where: { $0.s == job.rawValue }) {
                        Notice("Drag the cards into order, best in spot 1, then lock it in. You can also tap two cards to swap them.")
                    }
                    arena(row.mine)
                    if row.mine {
                        HStack(spacing: 1) {
                            Ghost(text: "Undo") { m.undo(job) }
                                .disabled(!m.log.contains { $0.s == job.rawValue })
                            Ghost(text: "Lock in", accent: true) { lockIn() }
                        }
                        .padding(.bottom, 1)
                    }
                }
            } else {
                Notice(m.error ?? "Loading the ranking…", error: m.error != nil)
                Spacer()
            }
        }
        .task { if m.state == nil { await m.load() } }
        .task { await m.watch() }
        .onChange(of: key(m), initial: true) { syncQuestion(m) }
    }

    /// Changes whenever the screen to show changes.
    private func key(_ m: RankingModel) -> String {
        guard let q = m.question(job) else { return "" }
        return "\(m.log.count)|\(q.cards)|\(q.pinned)"
    }

    private func syncQuestion(_ m: RankingModel) {
        let k = key(m)
        guard k != questionKey, let q = m.question(job) else { return }
        questionKey = k
        order = q.cards
        pinned = Set(q.pinned)
        picked = nil
        dragging = nil
    }

    private func header(_ st: RankingState, _ s: RankSession, _ row: RankingRow) -> some View {
        let used = st.knowledge.perJob[job.rawValue] ?? 0
        let place = s.top.count + 1
        let label = job == .final ? "Final" : job.title
        return VStack(alignment: .leading, spacing: 8) {
            if !row.mine { LabelText("Watching \(row.by?.displayName ?? "someone")'s ranking live") }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(s.done ? "✓" : "#\(place)").font(T1.mono(44, .bold)).foregroundStyle(T1.accent).monospacedDigit()
                VStack(alignment: .leading, spacing: 4) {
                    LabelText(s.done ? "\(label) · done" : "\(label) · deciding #\(place) of the top \(s.target)", color: T1.text)
                    Text("\(s.top.count) of the top \(s.target) (\(plural(s.size, "card"))) placed").font(T1.mono(12)).foregroundStyle(T1.muted)
                    Text(s.done ? "Done in \(plural(used, "screen"))"
                                : "Screen \((st.knowledge.screens + 1).formatted()) of this ranking · about \(max(1, st.expected(job) - used)) to go in \(label)")
                        .font(T1.mono(11)).foregroundStyle(T1.muted)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(T1.bg)
                    Rectangle().fill(T1.accent).frame(width: g.size.width * Double(s.top.count) / Double(max(1, s.target)))
                }
            }.frame(height: 3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T1.surface)
    }

    private func done(_ st: RankingState, _ s: RankSession) -> some View {
        VStack(spacing: 1) {
            Notice(job == .final ? "Top \(s.target) complete. All \(s.target) places are ranked." : "\(job.title) sorted.")
            Ghost(text: job == .final ? "Top \(s.target) list" : "\(job.title) list", accent: true) {
                path.append(.rankingLists(rankingId, job.rawValue))
            }
            Ghost(text: "Back to the ranking") { dismiss() }
        }
    }

    // MARK: the cards

    /// The cards, sized so every row fits the space left on screen; spot 1 top left.
    private func arena(_ mine: Bool) -> some View {
        GeometryReader { g in
            let cols = g.size.width > 600 ? 4 : 2
            let rows = max(1, (order.count + cols - 1) / cols)
            let gap: CGFloat = 12, label: CGFloat = 40
            let w = max(60, min((g.size.width - 32 - gap * CGFloat(cols - 1)) / CGFloat(cols),
                                ((g.size.height - 24 - gap * CGFloat(rows - 1)) / CGFloat(rows) - label) * CardArt.aspect))
            let h = w / CardArt.aspect + label
            let left = (g.size.width - (CGFloat(cols) * w + CGFloat(cols - 1) * gap)) / 2
            ZStack(alignment: .topLeading) {
                ForEach(Array(order.enumerated()), id: \.element) { i, x in
                    let origin = CGPoint(x: left + CGFloat(i % cols) * (w + gap), y: 12 + CGFloat(i / cols) * (h + gap))
                    cardView(x, spot: i + 1, width: w, mine: mine)
                        .offset(x: origin.x + (dragging == x ? dragAt.x - dragStart.x : 0),
                                y: origin.y + (dragging == x ? dragAt.y - dragStart.y : 0))
                        .zIndex(dragging == x ? 1 : 0)
                        .gesture(mine && !pinned.contains(x) ? drag(x, cols: cols, w: w, h: h, gap: gap, left: left) : nil)
                        .onTapGesture { if mine { tap(x) } }
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .coordinateSpace(name: "arena")
            .animation(.easeOut(duration: 0.18), value: order)
        }
        .frame(maxHeight: .infinity)
        .background(T1.bg)
    }

    private func cardView(_ x: Int, spot: Int, width: CGFloat, mine: Bool) -> some View {
        let c = model.card(x)
        let locked = pinned.contains(x)
        let up = picked == x || dragging == x
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if let p = c?.printing { p.art(width: width) } else {
                    RoundedRectangle(cornerRadius: width * 0.045).fill(T1.surfaceHover)
                        .frame(width: width, height: width / CardArt.aspect)
                        .overlay(Text(c?.name ?? "?").font(T1.mono(12)).padding(8), alignment: .topLeading)
                }
                Text("\(spot)").font(T1.mono(15, .bold)).monospacedDigit()
                    .frame(width: 28, height: 28).background(up ? T1.text : T1.surface).foregroundStyle(up ? T1.ink : T1.text)
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(T1.text)
                        .frame(width: 28, height: 28).background(T1.surface)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                        .accessibilityLabel("Locked: its order is already known")
                }
            }
            .overlay(RoundedRectangle(cornerRadius: width * 0.045).stroke(up ? T1.text : .clear, lineWidth: 3))
            Text(c?.name ?? "").font(T1.mono(11)).lineLimit(2).frame(width: width, height: 28, alignment: .topLeading)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spot \(spot): \(c?.name ?? "")")
    }

    private func drag(_ x: Int, cols: Int, w: CGFloat, h: CGFloat, gap: CGFloat, left: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("arena"))
            .onChanged { v in
                if dragging != x {
                    dragging = x
                    picked = nil
                    dragStart = v.startLocation
                }
                // The spot under the finger is the card's spot; the others shift around it.
                let col = min(cols - 1, max(0, Int((v.location.x - left + gap / 2) / (w + gap))))
                let row = max(0, Int((v.location.y - 12 + gap / 2) / (h + gap)))
                let target = min(order.count - 1, row * cols + col)
                if let from = order.firstIndex(of: x), from != target {
                    // Keep the card under the finger: shift the drag origin by how far its spot moved.
                    dragStart.x += CGFloat(target % cols - from % cols) * (w + gap)
                    dragStart.y += CGFloat(target / cols - from / cols) * (h + gap)
                    move(x, to: target)
                }
                dragAt = v.location
            }
            .onEnded { _ in dragging = nil }
    }

    private func move(_ x: Int, to target: Int) {
        guard let from = order.firstIndex(of: x) else { return }
        order.remove(at: from)
        order.insert(x, at: min(target, order.count))
    }

    /// First tap picks a card up; a second tap swaps them (on a placement screen the free card moves to that spot).
    private func tap(_ x: Int) {
        guard let p = picked else {
            if pinned.isEmpty || !pinned.contains(x) { picked = x } else if let free = order.first(where: { !pinned.contains($0) }),
                                                                             let spot = order.firstIndex(of: x) { move(free, to: spot) }
            return
        }
        picked = nil
        guard p != x, let i = order.firstIndex(of: p), let j = order.firstIndex(of: x) else { return }
        if pinned.isEmpty { order.swapAt(i, j) } else { move(p, to: j) }
    }

    private func lockIn() {
        guard order.count >= 2 else { return }
        model.lockIn(job, order: order)
    }
}

// MARK: lists

struct RankingListsView: View {
    let rankingId: String
    let job: RankJob
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var tab: RankJob?
    @State private var others: [RankingRow] = []
    @State private var copied = false
    private var model: RankingModel { RankingsStore.shared.model(rankingId) }

    var body: some View {
        let m = model
        let shown = tab ?? job
        T1Screen {
            Bar(title: shown == .final ? "Top \(m.row?.top ?? 100)" : shown.title, subtitle: m.row?.name, back: { dismiss() })
            if let st = m.state {
                rankingTabs(st, shown) { tab = $0 ?? .final }
                HairlineList {
                    if let l = m.list(shown) {
                        Notice(lede(st, shown))
                        ForEach(Array(l.placed.enumerated()), id: \.element.oracleId) { i, c in
                            Button { path.append(.rankingCard(rankingId, c.oracleId, shown.rawValue)) } label: {
                                CardRow(printing: c.printing, title: "\(i + 1). \(c.name)")
                            }.buttonStyle(.plain)
                        }
                        if let t = l.restTitle {
                            Section1(t)
                            ForEach(l.rest, id: \.oracleId) { c in
                                Button { path.append(.rankingCard(rankingId, c.oracleId, shown.rawValue)) } label: {
                                    CardRow(printing: c.printing, title: c.name)
                                }.buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 1) {
                            Ghost(text: copied ? "Copied" : "Copy list") {
                                UIPasteboard.general.string = m.listText(shown)
                                copied = true
                                Telemetry.capture("ranking_list_copied", ["list": shown.rawValue])
                            }
                            Ghost(text: "Compare…") {
                                if others.isEmpty { return }
                                T1Overlays.shared.showMenu("Compare this list with", others.map { o in
                                    T1MenuItem(title: "\(o.by?.displayName ?? "Someone") · \(o.name)") {
                                        path.append(.rankingCompare(rankingId, o.id, shown.rawValue))
                                    }
                                })
                            }
                        }
                    }
                }
            } else {
                Notice(m.error ?? "Loading the ranking…", error: m.error != nil)
                Spacer()
            }
        }
        .task { if m.state == nil { await m.load() } }
        .task { await m.watch() }
        .onChange(of: tab) { copied = false }
        .task(id: m.row?.listId) {
            guard let list = m.row?.listId, let r = try? await RankingsStore.shared.rankings(listId: list) else { return }
            others = r.rankings.filter { $0.id != rankingId }
        }
    }

    private func lede(_ st: RankingState, _ job: RankJob) -> String {
        let s = st.session(job)
        if s.top.isEmpty { return "Nothing ranked yet." }
        if job == .final { return s.done ? "Final order, #1 down." : "\(s.top.count) of \(s.target) ranked so far, #1 down." }
        if s.done && s.target < s.size {
            return "The top \(s.target) of \(s.size), best first. The other \(s.size - s.target) are below them, in no particular order."
        }
        return s.done ? "All \(s.size), best first." : "\(s.top.count) of the top \(s.target) placed so far, best first."
    }
}

/// Final · White · … · Lands, scrolling sideways.
/// `all`: an "All" tab first (the change log), selected when true; picking it passes nil.
private func rankingTabs(_ st: RankingState, _ shown: RankJob, all: Bool? = nil, _ select: @escaping (RankJob?) -> Void) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 1) {
            if let all {
                Button { select(nil) } label: {
                    LabelText("All", color: all ? T1.ink : T1.text).padding(.horizontal, 14).padding(.vertical, 12)
                        .background(all ? T1.text : T1.surface)
                }.buttonStyle(.plain)
            }
            ForEach([RankJob.final] + st.jobs, id: \.self) { j in
                let on = j == shown && all != true
                Button { select(j) } label: {
                    LabelText(j == .final ? "Top \(st.top)" : j.title, color: on ? T1.ink : T1.text)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(on ? T1.text : T1.surface)
                }.buttonStyle(.plain)
            }
        }
    }
    .background(T1.bg)
}

// MARK: one card's history

struct RankingCardView: View {
    let rankingId: String
    let oracleId: String
    let job: RankJob
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var against: String?
    private var model: RankingModel { RankingsStore.shared.model(rankingId) }

    var body: some View {
        let m = model
        let c = m.card(oracleId)
        T1Screen {
            Bar(title: c?.name ?? "Card", subtitle: m.row?.name, back: { dismiss() })
            if let st = m.state, let x = st.knowledge.index[oracleId.lowercased()] {
                let s = st.session(job)
                HairlineList {
                    HStack(alignment: .top, spacing: 16) {
                        if let p = c?.printing { p.art(width: 120) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(place(st, s, x)).font(T1.mono(15))
                            if job != .final, let fx = Optional(st.session(.final)), let i = fx.top.firstIndex(of: x) {
                                LabelText("#\(i + 1) in the top \(fx.target)")
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16).background(T1.surface)
                    why(st, s, x)
                    cardChanges(st, x)
                    screens(st, x)
                }
            } else {
                Notice(m.error ?? "Loading…", error: m.error != nil)
                Spacer()
            }
        }
        .task { if m.state == nil { await m.load() } }
    }

    private func place(_ st: RankingState, _ s: RankSession, _ x: Int) -> String {
        let where_ = job == .final ? "the top \(s.target)" : job.title
        if let i = s.top.firstIndex(of: x) { return "#\(i + 1) in \(where_)" }
        if s.done { return job == .final ? "Not in the top \(s.target)" : "Below the top \(s.target) in \(job.title)" }
        return job == .final ? "Not in the top \(s.target) yet" : "Not placed yet in \(job.title)"
    }

    /// Why is it above or below another card: the chain of screens that settled it.
    @ViewBuilder private func why(_ st: RankingState, _ s: RankSession, _ x: Int) -> some View {
        let me = st.id(x)
        let defaultOther: String? = s.top.firstIndex(of: x).flatMap { i in
            i > 0 ? st.id(s.top[i - 1]) : s.top.count > 1 ? st.id(s.top[1]) : nil
        } ?? s.top.last.map(st.id)
        let other = against ?? defaultOther
        Section1("Why")
        Button {
            let placed = s.top.filter { $0 != x }
            let inTop = Set(s.top)
            let rest = st.scope(job).members.filter { $0 != x && !inTop.contains($0) }
                .sorted { (model.card($0)?.name ?? "") < (model.card($1)?.name ?? "") }
            T1Overlays.shared.showMenu("Compare with", (placed + rest).prefix(150).map { y in
                let rank = s.top.firstIndex(of: y).map { "#\($0 + 1) " } ?? ""
                return T1MenuItem(title: rank + (model.card(y)?.name ?? "")) { against = st.id(y) }
            })
        } label: {
            ListRow(title: other.flatMap { model.card($0)?.name }.map { "Against \($0)" } ?? "Pick a card to compare", detail: "Change")
        }.buttonStyle(.plain)
        if let other {
            let name = model.card(me)?.name ?? "", otherName = model.card(other)?.name ?? ""
            if let chain = CubeRanking.why(st.knowledge, model.log, hi: me, lo: other) {
                Notice("\(name) is above \(otherName):")
                chainRows(chain)
            } else if let chain = CubeRanking.why(st.knowledge, model.log, hi: other, lo: me) {
                Notice("\(name) is below \(otherName):")
                chainRows(chain)
            } else {
                Notice("No screen has settled these two yet, directly or through other cards.")
            }
        }
    }

    @ViewBuilder private func chainRows(_ chain: [CubeRanking.Link]) -> some View {
        ForEach(chain, id: \.self) { l in
            ListRow(title: "\(model.card(l.winner)?.name ?? "?") above \(model.card(l.loser)?.name ?? "?")", detail: "Screen \(l.screen)")
        }
    }

    /// This card's moves in the change log, newest first.
    @ViewBuilder private func cardChanges(_ st: RankingState, _ x: Int) -> some View {
        let me = st.id(x)
        let rows = model.changes.filter { $0.c.lowercased() == me }.reversed()
        if !rows.isEmpty {
            Section1("Rank changes · \(rows.count)")
            ForEach(Array(rows.enumerated()), id: \.offset) { _, c in
                let list = RankJob(rawValue: c.s).map { $0 == .final ? "Top \(st.top)" : $0.title } ?? c.s
                ListRow(title: "\(list): \(RankingChangesView.move(c))", detail: [RankingChangesView.cause(c),
                        c.t.map { Date(timeIntervalSince1970: $0 / 1000).formatted(.dateTime.month(.abbreviated).day().hour().minute()) }]
                        .compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    /// Every screen this card was on, oldest first; your own can be redone.
    @ViewBuilder private func screens(_ st: RankingState, _ x: Int) -> some View {
        let me = st.id(x)
        let hits = model.log.enumerated().filter { $0.element.o.contains { $0.lowercased() == me } }
        Section1("Screens with this card · \(hits.count)")
        if hits.isEmpty { Notice("It has not been on a screen yet.") }
        ForEach(hits, id: \.offset) { i, sc in
            let names = sc.s == "P"
                ? "Picked \(model.card(sc.o[0])?.name ?? "?") over " + sc.o.dropFirst().map { model.card($0)?.name ?? "?" }.joined(separator: ", ")
                : sc.o.enumerated().map { "\($0.offset + 1). \(model.card($0.element)?.name ?? "?")" }.joined(separator: "\n")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    LabelText("Screen \(i + 1) · \(sc.job.map { $0 == .final ? "Final" : $0 == .pick ? "P1P1 pick (first card picked)" : $0.title } ?? "")")
                    Text(names).font(T1.mono(13)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if model.mine {
                    Button { askRedo(i, sc) } label: { LabelText("Redo", color: T1.text).padding(.vertical, 4) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T1.surface)
        }
    }

    private func askRedo(_ i: Int, _ sc: RankScreen) {
        let nothing = model.redoChangesNothing(i)
        let job = sc.job ?? .final
        T1Overlays.shared.ask("Remove screen \(i + 1)?",
                              message: nothing ? "Removing it changes nothing: other screens settle every order it did."
                                               : job == .pick ? "The pick comes out of the ranking."
                                               : "It comes out of the ranking and \(job == .final ? "the final" : job.title) asks about those cards again.",
                              action: "Remove and re-ask", destructive: true) {
            model.redo(i)
            if job != .pick { path.append(.rankingPick(rankingId, job.rawValue)) }
        }
    }
}

// MARK: compare

struct RankingCompareView: View {
    let rankingId: String
    let otherId: String
    let job: RankJob
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var a: String?
    @State private var b: String?
    @State private var tab: RankJob?
    @State private var all: [RankingRow] = []
    @State private var tracked = false
    @State private var brief: RankingBrief?
    @State private var briefError: String?
    @State private var briefTry = 0

    var body: some View {
        let ida = a ?? rankingId, idb = b ?? otherId
        let ma = RankingsStore.shared.model(ida), mb = RankingsStore.shared.model(idb)
        let shown = tab ?? job
        T1Screen {
            Bar(title: "Compare", subtitle: shown == .final ? "Top \(ma.row?.top ?? 100)" : shown.title, back: { dismiss() })
            if let sa = ma.state, let sb = mb.state, let ra = ma.row, let rb = mb.row {
                rankingTabs(sa, shown) { tab = $0 ?? .final }
                HairlineList {
                    pickers(ra, rb)
                    briefSection
                    content(sa, sb, ra, rb, shown)
                }
            } else {
                Notice(ma.error ?? mb.error ?? "Loading both rankings…", error: (ma.error ?? mb.error) != nil)
                Spacer()
            }
        }
        .task(id: ida) { if ma.state == nil { await ma.load() } }
        .task(id: idb) { if mb.state == nil { await mb.load() } }
        .task(id: ma.row?.listId) {
            guard let list = ma.row?.listId, let r = try? await RankingsStore.shared.rankings(listId: list) else { return }
            all = r.rankings
        }
        .onChange(of: "\(ida)|\(idb)|\(shown.rawValue)", initial: true) { tracked = false }
        .task(id: "\(ida)|\(idb)|\(shown.rawValue)|\(briefTry)") {
            brief = nil
            briefError = nil
            do { brief = try await RankingsStore.shared.brief(a: ida, b: idb, list: shown) } catch where !error.isCancellation {
                briefError = error.localizedDescription
            } catch {}
        }
    }

    /// Claude's few sentences on where the two agree and differ, above the numbers.
    @ViewBuilder private var briefSection: some View {
        Section1("In brief")
        if let text = brief?.brief {
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(T1.mono(13)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                LabelText(brief?.sample == true ? "Demo sample" : "Written by Claude from both rankings")
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(T1.surface)
        } else if let reason = brief?.reason {
            Notice(reason)
        } else if let briefError {
            Button { briefTry += 1 } label: { ListRow(title: "No brief yet", detail: "\(briefError) Tap to try again.") }.buttonStyle(.plain)
        } else {
            Notice("Writing a brief…")
        }
    }

    private func label(_ r: RankingRow) -> String { r.mine ? "You" : r.by?.displayName ?? "Someone" }

    @ViewBuilder private func pickers(_ ra: RankingRow, _ rb: RankingRow) -> some View {
        HStack(spacing: 1) {
            picker("Ranking", ra) { a = $0 }
            Button { let x = a ?? rankingId; a = b ?? otherId; b = x } label: {
                LabelText("Swap", color: T1.text).padding(.horizontal, 14).frame(maxHeight: .infinity).background(T1.surface)
            }.buttonStyle(.plain)
            picker("Compared with", rb) { b = $0 }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func picker(_ title: String, _ r: RankingRow, _ set: @escaping (String) -> Void) -> some View {
        Button {
            T1Overlays.shared.showMenu(title, all.map { o in
                T1MenuItem(title: "\(label(o)) · \(o.name)") { set(o.id) }
            })
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                LabelText(title)
                Text("\(label(r)) · \(r.name)").font(T1.mono(13)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(T1.surface)
        }.buttonStyle(.plain)
    }

    /// B's session in A's card indexes (both rank the same cube, but read it at different times).
    private func translate(_ s: RankSession, from kb: RankKnowledge, to ka: RankKnowledge) -> RankSession {
        RankSession(top: s.top.compactMap { ka.index[kb.ids[$0]] }, done: s.done, target: s.target, size: s.size,
                    question: nil, pinned: [], open: RankBits(count: ka.count))
    }

    @ViewBuilder private func content(_ sa: RankingState, _ sb: RankingState, _ ra: RankingRow, _ rb: RankingRow, _ job: RankJob) -> some View {
        let ka = sa.knowledge
        let c = CubeRanking.compare(ka, sa.session(job), translate(sb.session(job), from: sb.knowledge, to: ka), scope: sa.scope(job))
        let what = job == .final ? "cards" : "\(job.title.lowercased()) cards"
        let na = label(ra), nb = label(rb)
        let avg = "\(c.avgTenths / 10).\(c.avgTenths % 10)"
        if c.compared == 0 {
            Notice("Nothing to compare yet: these two rankings have no \(what) placed in common.")
        } else {
            Section1(job == .final ? "Biggest differences" : "\(job.title): biggest differences")
            Notice("Comparing \(plural(c.compared, job == .final ? "card" : "\(job.title.lowercased()) card")) both rankings have placed. " +
                   "On average they sit \(c.atLeast ? "at least " : "")\(avg) places apart; these \(c.biggest.count) differ the most." +
                   (job != .final && (ra.depth == "half" || rb.depth == "half")
                    ? " A ranking that sorts only the top half puts a card below its cut at the first place past it, so its gap is at least what's shown." : ""))
            ForEach(c.biggest, id: \.self) { gapRow($0, na, nb) }
            let oneSide = c.oneSide
            if !oneSide.isEmpty {
                Section1(job == .final ? "In one top \(sa.top), not the other" : "In one top half, not the other")
                Notice("\(plural(oneSide.count, "card")) \(oneSide.count == 1 ? "is" : "are") in one ranking's list but below the other's cut.")
                ForEach(oneSide, id: \.self) { gapRow($0, na, nb) }
            }
        }
        Color.clear.frame(height: 0).onAppear {
            guard !tracked else { return }
            tracked = true
            Telemetry.capture("ranking_compared", ["list": job.rawValue])
        }
    }

    private func gapRow(_ g: CubeRanking.Gap, _ na: String, _ nb: String) -> some View {
        let m = RankingsStore.shared.model(a ?? rankingId)
        let c = m.card(g.card)
        func side(_ name: String, _ p: Int, _ out: Bool) -> String { out ? "\(name): below the top \(p - 1)" : "\(name) #\(p)" }
        return Button { path.append(.rankingCard(a ?? rankingId, g.card, (tab ?? job).rawValue)) } label: {
            CardRow(printing: c?.printing, title: c?.name ?? "?", detail: "\(side(na, g.a, g.aOut)) · \(side(nb, g.b, g.bOut))") {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(g.atLeast ? "≥" : "")\(g.gap)").font(T1.mono(17)).monospacedDigit()
                    LabelText(g.gap == 1 ? "place" : "places")
                }
                .accessibilityLabel("\(g.atLeast ? "At least " : "")\(plural(g.gap, "place")) apart")
            }
        }.buttonStyle(.plain)
    }
}

// MARK: the top 100 as a picture

/// Piles of ten in rank order, each card over the one above so only its name bar shows (the last in a pile whole).
struct RankingImageCanvas: View {
    let title: String
    let byline: String
    let cards: [RankCard]
    let art: [String: UIImage]

    static let cw: CGFloat = 168
    static let ch: CGFloat = cw * 680 / 488
    static let peek: CGFloat = 26
    static let gap: CGFloat = 14
    static let pad: CGFloat = 32
    static let perPile = 10

    var piles: [[(Int, RankCard)]] {
        stride(from: 0, to: cards.count, by: Self.perPile).map { s in
            Array(cards.enumerated().map { ($0.offset, $0.element) }[s..<min(s + Self.perPile, cards.count)])
        }
    }

    var width: CGFloat { Self.pad * 2 + CGFloat(max(1, piles.count)) * (Self.cw + Self.gap) - Self.gap }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(T1.mono(30, .bold)).lineLimit(1).minimumScaleFactor(0.5)
                    Text(byline).font(T1.mono(14)).foregroundStyle(T1.muted).lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 8) {
                    T1Logo().fill(T1.text).aspectRatio(T1Logo.aspect, contentMode: .fit).frame(height: 30)
                    Text("TABLE-1.SITE").font(T1.mono(11)).tracking(2.5).foregroundStyle(T1.muted)
                }
            }
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(Array(piles.enumerated()), id: \.offset) { p, pile in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("#\(p * Self.perPile + 1)–\(p * Self.perPile + pile.count)").font(T1.mono(12)).tracking(2).foregroundStyle(T1.muted)
                        ZStack(alignment: .top) {
                            ForEach(pile, id: \.0) { i, c in tile(i, c).offset(y: CGFloat(i % Self.perPile) * Self.peek) }
                        }
                        .frame(width: Self.cw, height: Self.ch + CGFloat(pile.count - 1) * Self.peek, alignment: .top)
                    }
                }
            }
        }
        .padding(Self.pad)
        .frame(width: width, alignment: .topLeading)
        .background(T1.bg)
        .foregroundStyle(T1.text)
        .environment(\.colorScheme, .dark)
    }

    private func tile(_ i: Int, _ c: RankCard) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = c.printing.flatMap({ art[$0.cardId] }) {
                    Image(uiImage: img).resizable().interpolation(.high).scaledToFill()
                } else {
                    ZStack(alignment: .topLeading) { T1.surfaceHover; Text(c.name).font(T1.mono(11)).padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 30)) }
                }
            }
            .frame(width: Self.cw, height: Self.ch)
            .clipShape(RoundedRectangle(cornerRadius: Self.cw * CardCorners.ratio(set: c.printing?.set ?? ""), style: .circular))
            Text("\(i + 1)").font(T1.mono(11, .bold)).monospacedDigit().foregroundStyle(T1.ink)
                .frame(minWidth: 24, minHeight: 18).background(T1.text).offset(x: 4, y: 4)
        }
        .frame(width: Self.cw, height: Self.ch, alignment: .topLeading)
    }
}

struct RankingImagePanel: View {
    let model: RankingModel
    @State private var art: [String: UIImage] = [:]
    @State private var image: UIImage?
    @State private var progress: (done: Int, of: Int)?
    @State private var share: ShareFile?
    @State private var note: String?
    @State private var error: String?

    private var cards: [RankCard] { model.state.map { st in st.session(.final).top.compactMap(model.card) } ?? [] }

    var body: some View {
        T1Screen {
            Bar(title: "Top \(model.row?.top ?? 100) image", subtitle: model.row?.name, back: { T1Overlays.shared.dismissPanel() })
            HairlineList {
                if let error { Notice(error, error: true) }
                if let note { Notice(note) }
                if cards.isEmpty {
                    Notice("Nothing ranked in the final yet.")
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).accessibilityLabel("Top \(cards.count) image")
                } else if let progress {
                    Notice("Getting card images… \(progress.done) of \(progress.of)")
                } else {
                    Notice("Laying out the cards…")
                }
            }
            HStack(spacing: 1) {
                Ghost(text: "Save to Photos", accent: true) { Task { await save() } }
                Ghost(text: "Share") { shareImage() }
            }
            .padding(.bottom, 1)
            .disabled(image == nil)
        }
        .sheet(item: $share) { ShareSheet(share: $0).ignoresSafeArea() }
        .task {
            if model.state == nil { await model.load() }
            await prepare()
        }
    }

    private var byline: String {
        let row = model.row
        let date = Date.now.formatted(.dateTime.month(.abbreviated).day().year())
        let partial = (model.state?.session(.final).done ?? false) ? nil : "\(cards.count) of \(row?.top ?? 100) ranked so far"
        return [row.map { "\($0.mine ? "Your ranking" : "\($0.by?.displayName ?? "Someone")'s ranking") of \(model.cube?.name ?? "a cube")" },
                partial, "Ranked on Table 1", date].compactMap { $0 }.joined(separator: " · ")
    }

    private func prepare() async {
        let printings = Dictionary(cards.compactMap { c in c.printing.map { ($0.cardId, $0) } }, uniquingKeysWith: { a, _ in a })
        guard !printings.isEmpty else { return }
        progress = (0, printings.count)
        let maxPixel = 340
        var loaded: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for (id, p) in printings {
                group.addTask {
                    guard let url = p.imageURL(CardImageSize.covering(pixels: CGFloat(maxPixel)).rawValue) else { return (id, nil) }
                    return (id, await CardImageLoader.shared.image(url, maxPixel: maxPixel))
                }
            }
            for await (id, img) in group {
                if let img { loaded[id] = img }
                progress = (loaded.count, printings.count)
            }
        }
        if loaded.count < printings.count { note = "\(printings.count - loaded.count) card images couldn't be loaded; their names show instead." }
        art = loaded
        progress = nil
        let r = ImageRenderer(content: RankingImageCanvas(title: model.row?.name ?? "Top 100", byline: byline, cards: cards, art: art))
        r.scale = 2
        r.isOpaque = true
        image = r.uiImage
    }

    private func save() async {
        guard let image else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            error = "Table 1 can't add to Photos. Allow it in Settings → Table 1 → Photos, or use Share → Save Image."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            error = nil
            note = "Saved to Photos."
            Telemetry.capture("ranking_image", ["how": "photos"])
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func shareImage() {
        guard let data = image?.jpegData(compressionQuality: 0.9) else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "ranking-image")
            .appending(path: DeckImage.fileName(model.row?.name ?? "ranking"))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            share = ShareFile(url: url)
            Telemetry.capture("ranking_image", ["how": "share"])
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: P1P1: refine the ranking one pick at a time

/// A 15-card pack from the cube: pick one. The pick counts as the picked card beating the other 14; when the ranking
/// already says otherwise, the screen calls it out and lets you keep the ranking or let the pick win.
struct RankingPackView: View {
    let rankingId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var model: RankingModel { RankingsStore.shared.model(rankingId) }
    @State private var pack: [String] = []
    @State private var picked: String?
    /// After Pick: the verdict before it's saved (disagreements), or after (agreed / settled).
    @State private var verdict: Verdict?

    enum Verdict: Equatable {
        case disagree(picked: String, above: [String], removals: Int)
        case saved(String)
    }

    var body: some View {
        let m = model
        T1Screen {
            Bar(title: m.mine ? "P1P1" : "Pick history", subtitle: m.row?.name, back: { dismiss() })
            if m.state != nil, let row = m.row, !row.mine {
                HairlineList {
                    if m.picks.isEmpty { Notice("No P1P1 picks yet.") }
                    history
                }
            } else if m.state != nil, m.row != nil {
                HairlineList {
                    if let e = m.error { Notice(e, error: true) }
                    switch verdict {
                    case .disagree(let p, let above, let removals): disagreement(p, above, removals)
                    case .saved(let text):
                        Notice(text)
                        Ghost(text: "Next pack", accent: true) { next() }
                    case nil:
                        Notice("Pick the card you'd take first from this pack. Each pick refines your ranking: the card you take " +
                               "counts as better than the other \(max(0, pack.count - 1)).")
                    }
                    grid
                    if verdict == nil {
                        Ghost(text: picked.map { "Pick \(m.card($0)?.name ?? "")" } ?? "Tap a card to pick it", accent: picked != nil) { pick() }
                            .disabled(picked == nil)
                    }
                    history
                }
            } else {
                Notice(m.error ?? "Loading the ranking…", error: m.error != nil)
                Spacer()
            }
        }
        .task {
            if m.state == nil { await m.load() }
            if pack.isEmpty { pack = m.pack }
        }
    }

    private var grid: some View {
        let cols = 3
        return GeometryReader { g in
            let gap: CGFloat = 8
            let w = (g.size.width - 32 - gap * CGFloat(cols - 1)) / CGFloat(cols)
            VStack(alignment: .leading, spacing: gap) {
                ForEach(Array(stride(from: 0, to: pack.count, by: cols)), id: \.self) { start in
                    HStack(spacing: gap) {
                        ForEach(pack[start..<min(start + cols, pack.count)], id: \.self) { id in packCard(id, width: w) }
                    }
                }
            }
            .padding(16)
        }
        .frame(height: packHeight)
        .background(T1.bg)
    }

    private var packHeight: CGFloat {
        let w = (UIScreen.main.bounds.width - 32 - 16) / 3
        let rows = CGFloat((pack.count + 2) / 3)
        return 32 + rows * (w / CardArt.aspect) + max(0, rows - 1) * 8
    }

    private func packCard(_ id: String, width: CGFloat) -> some View {
        let c = model.card(id)
        let on = picked == id
        let flagged: Bool = { if case .disagree(let p, let above, _) = verdict { return id == p || above.contains(id) } else { return false } }()
        return Group {
            if let p = c?.printing { p.art(width: width) } else {
                RoundedRectangle(cornerRadius: width * 0.045).fill(T1.surfaceHover).frame(width: width, height: width / CardArt.aspect)
                    .overlay(Text(c?.name ?? "?").font(T1.mono(10)).padding(6), alignment: .topLeading)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: width * 0.045).stroke(on ? T1.accent : flagged ? T1.warning : .clear, lineWidth: 3))
        .onTapGesture { if verdict == nil && model.mine { picked = id } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(c?.name ?? "Card")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// "#3 in the top 100" / "#12 in White" / "not placed": where the ranking has a card now.
    private func place(_ id: String) -> String {
        guard let st = model.state, let x = st.knowledge.index[id.lowercased()] else { return "not ranked" }
        if let i = st.session(.final).top.firstIndex(of: x) { return "#\(i + 1) in the top \(st.top)" }
        if let job = st.category[id.lowercased()], let i = st.session(job).top.firstIndex(of: x) { return "#\(i + 1) in \(job.title)" }
        return "not placed yet"
    }

    @ViewBuilder private func disagreement(_ p: String, _ above: [String], _ removals: Int) -> some View {
        let name = model.card(p)?.name ?? "?"
        Section1("Your ranking disagrees")
        Notice("You picked \(name) (\(place(p))), but your ranking puts \(above.count == 1 ? "this card" : "these \(above.count) cards") above it:")
        ForEach(above, id: \.self) { id in
            CardRow(printing: model.card(id)?.printing, title: model.card(id)?.name ?? "?", detail: place(id))
        }
        HStack(spacing: 1) {
            Ghost(text: "Keep my ranking") { save(p, wins: false) }
            Ghost(text: "Let the pick win", accent: true) { save(p, wins: true) }
        }
        Notice(removals == 0 ? "Letting the pick win changes nothing else."
               : "Letting the pick win takes out \(plural(removals, "screen")) behind that order; those cards are asked about again.")
    }

    private func pick() {
        guard let p = picked else { return }
        let above = model.disagreements(picked: p, pack: pack)
        if above.isEmpty { save(p, wins: false) } else {
            verdict = .disagree(picked: p, above: above, removals: model.pickWinRemovals(picked: p, pack: pack).count)
        }
    }

    private func save(_ p: String, wins: Bool) {
        let disagreed = model.disagreements(picked: p, pack: pack).count
        let settles = model.newOrders(picked: p, pack: pack)
        model.pick(p, pack: pack, wins: wins)
        let name = model.card(p)?.name ?? "That pick"
        if disagreed > 0 {
            verdict = .saved(wins ? "\(name) now sits above the rest of that pack. Saved." : "Kept your ranking; the rest of the pick is saved.")
        } else if settles > 0 {
            verdict = .saved("\(name): this pick settles \(plural(settles, "order")) your ranking hadn't. Saved.")
        } else {
            verdict = .saved("\(name) agrees with your ranking. Saved.")
        }
    }

    private func next() {
        verdict = nil
        picked = nil
        pack = model.pack
    }

    @ViewBuilder private var history: some View {
        let picks = model.picks
        if !picks.isEmpty {
            Section1("Pick history · \(picks.count)")
            ForEach(picks, id: \.index) { p in
                let name = p.screen.o.first.flatMap { model.card($0)?.name } ?? "?"
                CardRow(printing: p.screen.o.first.flatMap { model.card($0)?.printing }, title: name,
                        detail: "Screen \(p.index + 1) · \(p.won ? "won over your ranking" : p.disagreed == 0 ? "agreed" : "disagreed with \(plural(p.disagreed, "card")), ranking kept") · \(place(p.screen.o[0]))")
            }
        }
    }
}

// MARK: change log

struct RankingChangesView: View {
    let rankingId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    @State private var filter: RankJob?
    private var model: RankingModel { RankingsStore.shared.model(rankingId) }

    var body: some View {
        let m = model
        T1Screen {
            Bar(title: "Changes", subtitle: m.row?.name, back: { dismiss() })
            if let st = m.state {
                rankingTabs(st, filter ?? .final, all: filter == nil) { filter = $0 }
                HairlineList {
                    let rows = m.changes.enumerated().filter { filter == nil || $0.element.s == filter?.rawValue }.reversed()
                    if rows.isEmpty { Notice("Nothing has moved yet.") }
                    let days = Dictionary(grouping: rows, by: { day($0.element.t) })
                    ForEach(days.keys.sorted(by: >), id: \.self) { d in
                        Section1(dayTitle(d))
                        ForEach(Array(days[d]!.prefix(500)), id: \.offset) { _, c in changeRow(c) }
                    }
                }
            } else {
                Notice(m.error ?? "Loading the ranking…", error: m.error != nil)
                Spacer()
            }
        }
        .task {
            if m.state == nil { await m.load() }
            Telemetry.capture("ranking_changes_opened")
        }
    }

    private func day(_ t: Double?) -> Double { ((t ?? 0) / 86_400_000).rounded(.down) }
    private func dayTitle(_ d: Double) -> String {
        d == 0 ? "Earlier" : Date(timeIntervalSince1970: d * 86_400).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func changeRow(_ c: RankChange) -> some View {
        let card = model.card(c.c)
        let list = RankJob(rawValue: c.s).map { $0 == .final ? "Top \(model.row?.top ?? 100)" : $0.title } ?? c.s
        return Button { path.append(.rankingCard(rankingId, c.c, c.s)) } label: {
            CardRow(printing: card?.printing, title: card?.name ?? "?", detail: "\(list) · \(RankingChangesView.cause(c))") {
                Text(RankingChangesView.move(c)).font(T1.mono(13)).monospacedDigit()
                    .foregroundStyle(c.to != nil && (c.f == nil || c.to! < c.f!) ? T1.text : T1.muted)
            }
        }.buttonStyle(.plain)
    }

    /// "#5 new", "#4 → #9", "#4 → out".
    static func move(_ c: RankChange) -> String {
        switch (c.f, c.to) {
        case (nil, let t?): "#\(t) new"
        case (let f?, nil): "#\(f) → out"
        case (let f?, let t?): "#\(f) → #\(t)"
        default: ""
        }
    }

    static func cause(_ c: RankChange) -> String {
        switch c.by {
        case "undo": "undo"
        case "redo": "redo screen \(c.n ?? 0)"
        case "pick": "P1P1 pick"
        case "pick_win": "a pick won"
        case "settings": "settings"
        default: c.n.map { "screen \($0)" } ?? "screen"
        }
    }
}
