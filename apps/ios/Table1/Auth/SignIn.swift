import AuthenticationServices
import CryptoKit
import GoogleSignIn
import Supabase
import UIKit

/// Apple and Google only, both through the system sheets (no browser hop).
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
    }

    static func signOut() async {
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
            await signOut()
        }
    }

    // MARK: Delete account

    /// Deletes the account. Apple users confirm with Apple once more so the server can revoke
    /// Table 1's Apple token (App Store guideline 5.1.1(v)); then the session is dropped locally.
    @MainActor
    static func deleteAccount() async throws {
        let code: String? = isAppleUser ? try await appleAuthorizationCode() : nil
        try await Repo.deleteAccount(appleAuthorizationCode: code)
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
