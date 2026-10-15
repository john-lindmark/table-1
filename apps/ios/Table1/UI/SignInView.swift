import AuthenticationServices
import SwiftUI

/// The mark, full-bleed, over the actions. Matches the "Sign in" frames in the Figma file.
/// Email is two steps under the mark: the address, then the code (or tap the link in the email).
struct SignInView: View {
    @Environment(SessionModel.self) private var session
    @State private var error: String?
    @State private var busy = false
    @State private var step: Step = .providers
    @State private var email = ""
    @State private var code = ""
    /// Supabase sends at most one email a minute per address.
    @State private var resendAt = Date.distantPast
    @FocusState private var focused: Bool

    enum Step { case providers, email, code }

    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.contains("@") && e.split(separator: "@").last?.contains(".") == true
    }
    private var codeValid: Bool { code.count >= 6 }

    var body: some View {
        VStack(spacing: 1) {
            SignInMark()
            if let message = error ?? session.emailLinkError { Notice(message, error: true) }
            switch step {
            case .providers: providers
            case .email: emailStep
            case .code: codeStep
            }
        }
        .background(T1.bg.ignoresSafeArea())
        .foregroundStyle(T1.text)
    }

    // MARK: steps

    @ViewBuilder private var providers: some View {
        SignInWithAppleButton(.continue) { request in
            SignIn.prepare(request)
        } onCompletion: { result in
            Task {
                do { try await SignIn.complete(result) } catch {
                    let cancelled = (error as? ASAuthorizationError)?.code == .canceled
                    Telemetry.capture("sign_in_failed", ["method": "apple", "reason": cancelled ? "cancelled" : "error"])
                    if !cancelled { self.error = "Sign-in failed. Try again."; Telemetry.error(error, "sign_in") }
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
                    do { try await SignIn.google() } catch {
                        // GIDSignInError.canceled is -5.
                        let cancelled = (error as NSError).domain == "com.google.GIDSignIn" && (error as NSError).code == -5
                        Telemetry.capture("sign_in_failed", ["method": "google", "reason": cancelled ? "cancelled" : "error"])
                        if !cancelled { self.error = "Sign-in failed. Try again."; Telemetry.error(error, "sign_in") }
                    }
                }
            }
        }
        Button { go(.email) } label: {
            Text("CONTINUE WITH EMAIL")
                .font(T1.mono(16, .bold)).tracking(5)
                .frame(maxWidth: .infinity).frame(height: 64)
                .background(T1.surface)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var emailStep: some View {
        input(label: "Email", text: $email, prompt: "name@example.com")
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.send)
            .onSubmit { if emailValid { send() } }
        HStack(spacing: 1) { Ghost(text: "Back") { go(.providers) } }
        BigAction(text: "Send code", enabled: emailValid, busy: busy, accent: true) { send() }
    }

    @ViewBuilder private var codeStep: some View {
        Notice("We sent a link and a code to \(email.trimmingCharacters(in: .whitespaces)). Tap the link on this phone, or enter the code.")
        input(label: "Code", text: $code, prompt: "000000")
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .onChange(of: code) { _, new in
                let digits = String(new.filter(\.isNumber).prefix(10))
                if digits != new { code = digits }
            }
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = max(0, Int(resendAt.timeIntervalSince(context.date).rounded(.up)))
            HStack(spacing: 1) {
                Ghost(text: "Change email") { code = ""; go(.email) }
                Ghost(text: wait > 0 ? "Resend in \(wait)s" : "Resend") { if wait == 0 { send() } }
                    .disabled(wait > 0 || busy)
            }
        }
        BigAction(text: "Sign in", enabled: codeValid, busy: busy, accent: true) { verify() }
    }

    private func input(label: String, text: Binding<String>, prompt: String) -> some View {
        SignInField(label: label, text: text, prompt: prompt).focused($focused)
    }

    // MARK: actions

    private func go(_ next: Step) {
        error = nil
        session.emailLinkError = nil
        step = next
        focused = next != .providers
    }

    private func send() {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        busy = true
        Task {
            defer { busy = false }
            do {
                try await SignIn.sendEmailCode(to: address)
                resendAt = Date().addingTimeInterval(60)
                if step != .code { go(.code) } else { error = nil }
            } catch {
                Telemetry.capture("sign_in_failed", ["method": "email_send", "reason": "error"])
                Telemetry.error(error, "sign_in")
                self.error = "Couldn't send the email. Check the address and try again in a minute."
            }
        }
    }

    private func verify() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await SignIn.verifyEmailCode(email: email.trimmingCharacters(in: .whitespaces).lowercased(), code: code)
            } catch {
                Telemetry.capture("sign_in_failed", ["method": "email_code", "reason": "error"])
                self.error = "That code didn't work. Check it, or send a new one."
            }
        }
    }
}

/// The mark, full-bleed on the surface band, above every sign-in step.
private struct SignInMark: View {
    var body: some View {
        T1Logo()
            .fill(T1.text)
            .aspectRatio(T1Logo.aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 40)
            .background(T1.surface.ignoresSafeArea(edges: .top))
            .accessibilityElement()
            .accessibilityLabel("Table 1")
            .accessibilityAddTraits(.isHeader)
    }
}

private struct SignInField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabelText(label)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(T1.muted))
                .font(T1.mono(15)).tint(T1.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T1.surface)
    }
}

/// New email accounts: first and last name, both required, before the app opens.
struct NameView: View {
    @Environment(SessionModel.self) private var session
    @State private var first = ""
    @State private var last = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var field: Field?

    private enum Field { case first, last }

    private var valid: Bool {
        !first.trimmingCharacters(in: .whitespaces).isEmpty && !last.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 1) {
            SignInMark()
            if let error { Notice(error, error: true) }
            Notice("Add your name. Opponents and organizers see it on pairings and standings.")
            SignInField(label: "First name", text: $first, prompt: "First name")
                .textContentType(.givenName).textInputAutocapitalization(.words).autocorrectionDisabled()
                .submitLabel(.next).focused($field, equals: .first)
                .onSubmit { field = .last }
            SignInField(label: "Last name", text: $last, prompt: "Last name")
                .textContentType(.familyName).textInputAutocapitalization(.words).autocorrectionDisabled()
                .submitLabel(.done).focused($field, equals: .last)
                .onSubmit { if valid { save() } }
            HStack(spacing: 1) { Ghost(text: "Sign out") { Task { await SignIn.signOut() } } }
            BigAction(text: "Continue", enabled: valid, busy: busy, accent: true) { save() }
        }
        .background(T1.bg.ignoresSafeArea())
        .foregroundStyle(T1.text)
        .onAppear { field = .first }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await SignIn.saveName(first: first, last: last)
                session.needsName = false
            } catch {
                Telemetry.error(error, "sign_in_name")
                self.error = "Couldn't save your name. Try again."
            }
        }
    }
}
