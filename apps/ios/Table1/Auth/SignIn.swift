import AuthenticationServices
import CryptoKit
import GoogleSignIn
import Supabase
import UIKit

/// Apple and Google through the system sheets (no browser hop), or a one-time email code.
enum SignIn {
    // MARK: Apple

    /// Raw nonce for the request in flight; Apple gets its SHA-256, Supabase gets the raw value.
    private(set) static var currentNonce = ""

    static func prepare(_ request: ASAuthorizationAppleIDRequest) {
        currentNonce = randomNonce()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(currentNonce)
    }

    static func complete(_ result: Result<ASAuthorization, Error>) async throws {
        let authorization = try result.get()
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw SignInError.missingToken
        }
        try await supabase.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: currentNonce)
        )
        Telemetry.capture("signed_in", ["method": "apple"])
        // Remembered so launch can ask Apple whether this Apple ID still allows Table 1.
        UserDefaults.standard.set(credential.user, forKey: appleUserKey)
        // Apple sends the name only on the very first authorization.
        if let name = credential.fullName {
            let full = [name.givenName, name.familyName].compactMap { $0 }.joined(separator: " ")
            await Repo.saveDisplayName(full)
        }
    }

    // MARK: Google

    /// False until a real iOS client ID is in Info.plist (GIDClientID). The Google SDK
    /// crashes if asked to sign in without its URL scheme, so the button stays hidden.
    static var googleConfigured: Bool {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else { return false }
        return !id.isEmpty && !id.contains("REPLACE")
    }

    @MainActor
    static func google() async throws {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
            throw SignInError.noWindow
        }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: root)
        guard let idToken = result.user.idToken?.tokenString else { throw SignInError.missingToken }
        try await supabase.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(
                provider: .google,
                idToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
        )
        Telemetry.capture("signed_in", ["method": "google"])
    }

    // MARK: Email

    /// Sends the sign-in email (a link and the same code). New addresses get an account.
    static func sendEmailCode(to email: String) async throws {
        try await supabase.auth.signInWithOTP(email: email, shouldCreateUser: true)
        Telemetry.capture("sign_in_email_sent")
    }

    /// The code typed from the email.
    static func verifyEmailCode(email: String, code: String) async throws {
        try await supabase.auth.verifyOTP(email: email, token: code, type: .email)
        Telemetry.capture("signed_in", ["method": "email_code"])
    }

    /// The email's button: https://table-1.site/auth/confirm?token_hash=…&type=email, opened as a universal link.
    /// Returns false for any other URL.
    static func handleEmailLink(_ url: URL) async throws -> Bool {
        guard url.host == "table-1.site", url.path.hasPrefix("/auth/confirm"),
              let hash = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "token_hash" })?.value, !hash.isEmpty else { return false }
        try await supabase.auth.verifyOTP(tokenHash: hash, type: .email)
        Telemetry.capture("signed_in", ["method": "email_link"])
        return true
    }

    /// Email accounts start without a name, so one is required before the app opens.
    /// Apple and Google bring theirs; any account that has a first name saved is done.
    static func needsName(_ user: User?) -> Bool {
        guard let user, let identities = user.identities, !identities.isEmpty,
              identities.allSatisfy({ $0.provider == "email" }) else { return false }
        return (user.userMetadata["first_name"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// First and last name: kept on the account and shown in events as "First Last".
    static func saveName(first: String, last: String) async throws {
        let first = first.trimmingCharacters(in: .whitespaces), last = last.trimmingCharacters(in: .whitespaces)
        let full = "\(first) \(last)"
        try await Repo.setDisplayName(full)
        _ = try await supabase.auth.update(user: UserAttributes(data: [
            "first_name": .string(first), "last_name": .string(last), "full_name": .string(full),
        ]))
        Telemetry.capture("name_added")
    }

    static func signOut(reason: String = "user") async {
        Telemetry.capture("signed_out", ["reason": reason])
        Telemetry.reset()
        await LiveActivityController.shared.didSignOut()
        try? await supabase.auth.signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    // MARK: Apple account state

    private static let appleUserKey = "t1.appleUserID"

    /// True when the signed-in account came from Sign in with Apple.
    static var isAppleUser: Bool {
        supabase.auth.currentUser?.identities?.contains { $0.provider == "apple" } ?? false
    }

    /// People can stop using Apple ID with Table 1 in Settings. Checked on launch, on every return
    /// to the foreground and when Apple posts a revocation; a revoked or missing credential signs out.
    static func checkAppleCredential() async {
        guard let appleUser = UserDefaults.standard.string(forKey: appleUserKey) else { return }
        let state: ASAuthorizationAppleIDProvider.CredentialState = await withCheckedContinuation { cont in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleUser) { state, _ in
                cont.resume(returning: state)
            }
        }
        if state == .revoked || state == .notFound {
            UserDefaults.standard.removeObject(forKey: appleUserKey)
            await signOut(reason: "apple_revoked")
        }
    }

    // MARK: Delete account

    /// Deletes the account. Apple users confirm with Apple once more so the server can revoke
    /// Table 1's Apple token (App Store guideline 5.1.1(v)); then the session is dropped locally.
    @MainActor
    static func deleteAccount() async throws {
        let code: String? = isAppleUser ? try await appleAuthorizationCode() : nil
        try await Repo.deleteAccount(appleAuthorizationCode: code)
        Telemetry.capture("account_deleted")
        Telemetry.reset()
        UserDefaults.standard.removeObject(forKey: appleUserKey)
        await LiveActivityController.shared.didSignOut()
        try? await supabase.auth.signOut(scope: .local)
        GIDSignIn.sharedInstance.signOut()
    }

    /// A fresh Apple authorization code (they expire after five minutes, so ask right before use).
    @MainActor
    private static func appleAuthorizationCode() async throws -> String {
        let delegate = AppleCodeDelegate()
        pendingAppleRequest = delegate      // ASAuthorizationController holds its delegate weakly
        defer { pendingAppleRequest = nil }
        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: [ASAuthorizationAppleIDProvider().createRequest()])
            controller.delegate = delegate
            controller.presentationContextProvider = delegate
            controller.performRequests()
        }
    }

    @MainActor private static var pendingAppleRequest: AppleCodeDelegate?

    // MARK: helpers

    enum SignInError: LocalizedError {
        case missingToken, noWindow
        var errorDescription: String? {
            switch self {
            case .missingToken: "Sign-in didn't return a token. Try again."
            case .noWindow: "Couldn't show the sign-in sheet."
            }
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Bridges ASAuthorizationController's delegate callbacks to async/await.
private final class AppleCodeDelegate: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    var continuation: CheckedContinuation<String, Error>?

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.authorizationCode,
              let code = String(data: data, encoding: .utf8) else {
            finish(.failure(SignIn.SignInError.missingToken))
            return
        }
        finish(.success(code))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }

    private func finish(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
