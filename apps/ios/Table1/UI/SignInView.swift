import AuthenticationServices
import SwiftUI

/// The mark, full-bleed, over the actions. Matches the "Sign in" frames in the Figma file.
/// Email is two steps under the mark: the address, then the code (or tap the link in the email).
struct SignInView: View {
    @Environment(SessionModel.self) private var session
    @State private var error: String?
    @State private var busy = false
    /// Discord's web sheet is open.
    @State private var discordBusy = false
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
            if let join = session.pendingJoin { JoinHeader(link: join) }
            else if let page = session.pendingSignUp { SignUpHeader(page: page) }
            if let message = error ?? session.emailLinkError { Notice(message, error: true) }
            switch step {
            case .providers: providers
            case .email: emailStep
            case .code: codeStep
            }
        }
        .background(T1.bg.ignoresSafeArea())
        .foregroundStyle(T1.text)
        // Back from Mail (or relaunched by iOS meanwhile): the code step for the address a code just went to.
        .onAppear {
            guard step == .providers, let pending = EmailSignIn.load() else { return }
            email = pending.email
            resendAt = pending.resendAt
            step = .code
        }
    }

    // MARK: steps

    @ViewBuilder private var providers: some View {
        SignInWithAppleButton(.continue) { request in
            SignIn.prepare(request)
        } onCompletion: { result in
            Task {
                do { try await SignIn.complete(result) } catch { failed(error, method: "apple") }
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
                    do { try await SignIn.google() } catch { failed(error, method: "google") }
                }
            }
        }
        Button { discord() } label: {
            Text(discordBusy ? "OPENING DISCORD…" : "CONTINUE WITH DISCORD")
                .font(T1.mono(16, .bold)).tracking(5)
                .frame(maxWidth: .infinity).frame(height: 64)
                .background(T1.surface)
        }
        .buttonStyle(.plain)
        .disabled(busy || discordBusy)
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
        Notice("We sent a link and a code to \(email.trimmingCharacters(in: .whitespaces)). Tap the link on this phone, or enter the code. Not there? Check spam.")
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
                Ghost(text: "Change email") { code = ""; EmailSignIn.clear(); go(.email) }
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

    private func discord() {
        guard !discordBusy else { return }
        error = nil
        discordBusy = true
        Task {
            defer { discordBusy = false }
            do { try await SignIn.discord() } catch { failed(error, method: "discord") }
        }
    }

    /// Apple, Google or Discord ended without signing in: say so unless it was a cancel; report only real failures.
    private func failed(_ error: Error, method: String) {
        let failure = SignIn.Failure(error)
        Telemetry.capture("sign_in_failed", ["method": method, "reason": failure.reason])
        if let message = failure.message { self.error = message }
        if failure == .failed { Telemetry.error(error, "sign_in") }
    }

    /// Send, Resend and the keyboard's Send key all land here; one send at a time.
    private func send() {
        guard !busy else { return }
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        busy = true
        Task {
            defer { busy = false }
            do {
                try await SignIn.sendEmailCode(to: address)
                codeSent(EmailSignIn.pending(email: address, now: .now))
            } catch {
                switch EmailSignIn.outcome(error) {
                case .alreadySent(let wait):
                    // The minute per address: a code went out moments ago, so that's the step to be on.
                    Telemetry.capture("sign_in_failed", ["method": "email_send", "reason": "already_sent"])
                    codeSent(EmailSignIn.pending(email: address, now: .now, wait: wait))
                case .tooMany:
                    Telemetry.capture("sign_in_failed", ["method": "email_send", "reason": "too_many"])
                    self.error = "Too many sign-in emails right now. Wait a few minutes, or continue with Apple or Google."
                case .failed:
                    Telemetry.capture("sign_in_failed", ["method": "email_send", "reason": "error"])
                    Telemetry.error(error, "sign_in")
                    self.error = "Couldn't send the email. Check the address and try again."
                }
            }
        }
    }

    private func codeSent(_ pending: EmailSignIn.Pending) {
        EmailSignIn.save(pending)
        resendAt = pending.resendAt
        if step != .code { go(.code) } else { error = nil }
    }

    private func verify() {
        guard !busy else { return }
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

/// A scanned join QR waiting on sign-in: which event it is, and that any way in (a new account too) takes the seat.
private struct JoinHeader: View {
    let link: JoinLink
    /// On the name step, after sign-in.
    var naming = false
    @State private var preview: JoinPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabelText("Joining")
            Text(preview?.title ?? "Event \(link.code.uppercased())").font(T1.mono(17, .bold))
            if let facts = preview?.facts { Text(facts).font(T1.mono(12)).foregroundStyle(T1.muted) }
            Text(naming ? "Add your name and you're in." : "New to Table 1? Any option below makes your account. You're seated as soon as you're in.")
                .font(T1.mono(12)).lineSpacing(4).foregroundStyle(T1.muted).padding(.top, 4)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T1.surface)
        .task(id: link.code) {
            preview = await Repo.joinPreview(code: link.code)
            if !naming { Telemetry.capture("join_prompt_viewed", ["event": preview != nil]) }
        }
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
            if let join = session.pendingJoin { JoinHeader(link: join, naming: true) }
            else if let page = session.pendingSignUp { SignUpHeader(page: page, naming: true) }
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

/// After sign-in (and the name step), once per device: why notifications and location help, before iOS asks.
/// Turn on shows the system prompts for whichever is still unasked; Skip for now goes straight in and nothing asks
/// again on its own (contract/permissions-onboarding-2026-10-28.md).
struct PermissionsView: View {
    @Environment(SessionModel.self) private var session
    @State private var notifications: PermissionState = .unasked
    @State private var location: PermissionState = .unasked
    @State private var busy = false

    var body: some View {
        VStack(spacing: 1) {
            SignInMark()
            PermissionRow(
                title: "Notifications", state: notifications,
                text: "Know the moment your round is paired, when your opponent reports a result and when you're invited to an event. Friends' trades and price drops on your wants too."
            )
            PermissionRow(
                title: "Location", state: location,
                text: "See events starting near you and join without a code, and pin your own event to the venue. Only while the app is open, and only a rough area is kept, never your exact spot."
            )
            Notice("Change either any time in iOS Settings.")
            HStack(spacing: 1) { Ghost(text: "Skip for now") { finish("skip") } }
            BigAction(text: "Turn on", busy: busy, accent: true) { turnOn() }
        }
        .background(T1.bg.ignoresSafeArea())
        .foregroundStyle(T1.text)
        .task { if let state = await PermissionsStep.notifications() { notifications = state } }
        .task { location = await PermissionsStep.location() }
    }

    private func turnOn() {
        busy = true
        Task {
            if notifications == .unasked { notifications = await PushController.shared.ask() ? .on : .off }
            if location == .unasked { location = await LocationFix.shared.ask() ? .on : .off }
            finish("turn_on")
        }
    }

    private func finish(_ choice: String) {
        Telemetry.capture("onboarding_permissions", [
            "choice": choice, "notifications": "\(notifications)", "location": "\(location)",
        ])
        PermissionsStep.seen = true
        session.needsPermissions = false
    }
}

private struct PermissionRow: View {
    let title: String
    let state: PermissionState
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(T1.mono(13, .bold)).tracking(3)
                Spacer()
                switch state {
                case .on: LabelText("On", color: T1.accent)
                case .off: LabelText("Off")
                case .unasked: EmptyView()
                }
            }
            Text(text).font(T1.mono(12)).lineSpacing(4).foregroundStyle(T1.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(T1.surface)
        .accessibilityElement(children: .combine)
    }
}
