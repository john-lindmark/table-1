import AuthenticationServices
import SwiftUI

/// Lifetime record and head-to-head against every opponent.
struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ProfileRow?
    @State private var life = PlayerRecord()
    @State private var rivals: [Repo.Rival]?
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var deleting = false

    var body: some View {
        T1Screen {
            Bar(title: profile?.label ?? "My record", subtitle: "Lifetime") { BarButton("Back") { dismiss() } }
            if let error { Notice(error, error: true) }
            VStack(spacing: 4) {
                Text(recordText(life.matchWins, life.matchLosses, life.matchDraws))
                    .font(T1.mono(48)).tracking(4).foregroundStyle(T1.accent)
                LabelText("\(life.matchWins + life.matchLosses + life.matchDraws) matches · games \(recordText(life.gameWins, life.gameLosses, life.gameDraws))\(life.byes > 0 ? " · \(life.byes) byes" : "")")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24).background(T1.surface)
            Section1("Head-to-head")
            HairlineList {
                if let rivals {
                    if rivals.isEmpty { Notice("Play a match to start your head-to-head.") }
                    ForEach(rivals) { r in
                        ListRow(title: r.name, detail: "games \(recordText(r.row.gameWins, r.row.gameLosses, r.row.gameDraws))") {
                            Text(recordText(r.row.matchWins, r.row.matchLosses, r.row.matchDraws)).font(T1.mono(16))
                        }
                    }
                } else {
                    Notice("Loading…")
                }
            }
            Section1("Account")
            Ghost(text: "Sign out") { Task { await SignIn.signOut() } }
            Ghost(text: deleting ? "Deleting…" : "Delete account") { if !deleting { confirmDelete = true } }
        }
        .confirmationDialog("Delete your Table 1 account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your sign-in, name and devices are removed. Results you played stay in their events as \"Deleted player\". This can't be undone."
                 + (SignIn.isAppleUser ? " You'll confirm with Apple once more." : ""))
        }
        .task {
            do {
                profile = try await Repo.myProfile()
                life = try await Repo.myRecord() ?? PlayerRecord()
                rivals = try await Repo.myRivals()
            } catch {
                self.error = error.localizedDescription
                rivals = []
            }
        }
    }

    private func deleteAccount() {
        deleting = true
        Task {
            do {
                try await SignIn.deleteAccount()   // session ends; RootView switches to sign-in
            } catch {
                self.error = (error as? ASAuthorizationError)?.code == .canceled
                    ? nil : "Couldn't delete the account: \(error.localizedDescription)"
                deleting = false
            }
        }
    }
}
