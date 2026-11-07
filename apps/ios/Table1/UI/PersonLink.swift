import SwiftUI

/* A person is a way to their profile (contract/friends-sharing-2026-10-18.md § Tapping a person). Wherever a player or
   another account is drawn with an account behind it (an avatar, a standings or players row, an opponent's name), a tap
   opens their profile, where Add friend is. Guests (no account) aren't tappable. A row whose own tap does something else
   keeps it; there only the avatar opens the profile.

   Each tab's NavigationStack sets `openProfile` to push the profile on its own path, so Back returns to where you were. Panels
   drawn over the tabs (T1Overlays) have no opener, and nothing there is tappable. */

extension EnvironmentValues {
    @Entry var openProfile: ((String) -> Void)? = nil
}

enum PersonLink {
    /// Whose profile a tap opens: nil for a guest or an empty id.
    static func target(_ userId: String?) -> String? {
        guard let id = userId?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        return id.lowercased()
    }
}

private struct OpensProfile: ViewModifier {
    let userId: String?
    let from: String
    @Environment(\.openProfile) private var openProfile

    func body(content: Content) -> some View {
        if let id = PersonLink.target(userId), let openProfile {
            content
                .contentShape(Rectangle())
                // A tap gesture, not a Button: buttons inside the row (Drop, Let in, List) keep their own taps.
                .onTapGesture {
                    Telemetry.capture("person_tapped", ["from": from])
                    openProfile(id)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens their profile")
        } else {
            content
        }
    }
}

extension View {
    /// Tapping this opens `userId`'s profile (nothing for a guest). `from` names the place for telemetry.
    func opensProfile(_ userId: String?, from: String) -> some View {
        modifier(OpensProfile(userId: userId, from: from))
    }
}
