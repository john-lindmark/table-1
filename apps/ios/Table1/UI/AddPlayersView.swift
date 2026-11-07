import SwiftUI

/// Invite people to an event you're organizing. Friends come first, then people you've shared the most events
/// with; search narrows both. Email reaches existing accounts only and never says whether one exists.
struct AddPlayersView: View {
    let eventId: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var people: [SuggestedPlayer]?
    @State private var picked = Set<String>()
    @State private var email = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        T1Screen {
            Bar(title: "Add players", subtitle: "Invitations — they accept to take a seat") {
                BarButton("Done") { dismiss() }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(T1.muted)
                TextField("", text: $query, prompt: Text("Search friends and people you've played with").foregroundStyle(T1.muted))
                    .font(T1.mono(15)).tint(T1.accent)
                    .textInputAutocapitalization(.words).autocorrectionDisabled()
            }
            .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)

            HairlineList {
                if let error { Notice(error, error: true) }
                if let notice { Notice(notice) }

                if let people {
                    let friends = people.filter { $0.friend == true }
                    if !friends.isEmpty {
                        Section1("Friends · \(friends.count)")
                        ForEach(friends) { row($0) }
                    }
                    Section1(query.isEmpty ? "Suggested · played with you most" : friends.isEmpty ? "Matches" : "Played with you")
                    let others = people.filter { $0.friend != true }
                    if others.isEmpty {
                        Notice(query.isEmpty
                               ? (friends.isEmpty ? "No one yet. Friends and people you play with show up here; until then, invite by email below or share the QR from the event."
                                                  : "People you play with show up here too.")
                               : "No one else you've played with matches \"\(query)\".")
                    }
                    ForEach(others) { row($0) }
                } else {
                    Notice("Loading…")
                }

                Section1("Invite by email")
                HStack(spacing: 1) {
                    TextField("", text: $email, prompt: Text("name@example.com").foregroundStyle(T1.muted))
                        .font(T1.mono(15)).tint(T1.accent)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(.horizontal, 16).padding(.vertical, 14).background(T1.surface)
                    Button { sendEmail() } label: {
                        LabelText("Send", color: emailValid ? T1.ink : T1.muted)
                            .padding(.horizontal, 20).padding(.vertical, 16)
                            .background(emailValid ? T1.accent : T1.surface)
                    }
                    .buttonStyle(.plain)
                    .disabled(!emailValid || busy)
                }
                Notice("Works for people who already have a Table 1 account. For anyone else, show them the event's QR code.")
            }
            BigAction(text: picked.isEmpty ? "Select players" : "Invite \(picked.count)", enabled: !picked.isEmpty, busy: busy, accent: true) {
                invite()
            }
        }
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func row(_ p: SuggestedPlayer) -> some View {
        let detail = p.friend == true
            ? (p.sharedEvents > 0 ? "Friend · \(p.sharedEvents) event\(p.sharedEvents == 1 ? "" : "s") together" : "Friend")
            : "\(p.sharedEvents) event\(p.sharedEvents == 1 ? "" : "s") together"
        return Button { toggle(p) } label: {
            ListRow(title: p.label, detail: detail, avatar: AvatarView(name: p.displayName, userId: p.userId, opensFrom: "add_players")) {
                if p.invited {
                    LabelText("Invited", color: T1.muted)
                } else {
                    Image(systemName: picked.contains(p.userId) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 20))
                        .foregroundStyle(picked.contains(p.userId) ? T1.accent : T1.muted)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(p.invited)
        .sensoryFeedback(.selection, trigger: picked.contains(p.userId))
    }

    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.count > 5 && e.contains("@") && e.split(separator: "@").last?.contains(".") == true
    }

    private func toggle(_ p: SuggestedPlayer) {
        if picked.contains(p.userId) { picked.remove(p.userId) } else { picked.insert(p.userId) }
    }

    private func load() async {
        await BuildFlavor.resolve()
        do {
            people = try await Repo.suggestedPlayers(eventId, query: query)
            error = nil
        } catch {
            self.error = error.localizedDescription
            if people == nil { people = [] }
        }
    }

    private func invite() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let friends = people?.filter { $0.friend == true && picked.contains($0.userId) }.count ?? 0
                let n = try await Repo.invitePlayers(eventId, userIds: Array(picked), friends: friends)
                picked.removeAll()
                notice = n == 1 ? "1 invitation sent." : "\(n) invitations sent."
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func sendEmail() {
        busy = true
        error = nil
        let address = email.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                try await Repo.inviteByEmail(eventId, email: address)
                email = ""
                notice = "If \(address) has a Table 1 account, they'll get your invite."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
