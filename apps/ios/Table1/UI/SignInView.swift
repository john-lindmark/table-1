import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        T1Screen {
            Bar(title: "Table 1", subtitle: "Sign in")
            Notice("Run events, join by QR or nearby, and keep your record and head-to-head across every event.")
            if let error { Notice(error, error: true) }
            Spacer()
            SignInWithAppleButton(.continue) { request in
                SignIn.prepare(request)
            } onCompletion: { result in
                Task {
                    do { try await SignIn.complete(result) } catch { self.error = error.localizedDescription }
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 64)
            .clipShape(Rectangle())
            BigAction(text: "Continue with Google", busy: busy, accent: true) {
                busy = true
                Task {
                    defer { busy = false }
                    do { try await SignIn.google() } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}
