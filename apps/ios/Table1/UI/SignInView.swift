import AuthenticationServices
import SwiftUI

/// The mark, full-bleed, over the actions. Matches the "Sign in" frames in the Figma file.
struct SignInView: View {
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 1) {
            T1Logo()
                .fill(T1.text)
                .aspectRatio(T1Logo.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 40)
                .background(T1.surface.ignoresSafeArea(edges: .top))
                .accessibilityElement()
                .accessibilityLabel("Table 1")
                .accessibilityAddTraits(.isHeader)
            if let error { Notice(error, error: true) }
            SignInWithAppleButton(.continue) { request in
                SignIn.prepare(request)
            } onCompletion: { result in
                Task {
                    do { try await SignIn.complete(result) } catch {
                        if (error as? ASAuthorizationError)?.code != .canceled { self.error = "Sign-in failed. Try again." }
                    }
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 64)
            .clipShape(Rectangle())
            if SignIn.googleConfigured {
                BigAction(text: "Continue with Google", busy: busy, accent: true) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await SignIn.google() } catch { self.error = "Sign-in failed. Try again." }
                    }
                }
            }
        }
        .background(T1.bg.ignoresSafeArea())
        .foregroundStyle(T1.text)
    }
}
