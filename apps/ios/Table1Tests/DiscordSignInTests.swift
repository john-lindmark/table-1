import AuthenticationServices
import Supabase
import XCTest
@testable import Table1

/* Sign in with Discord (contract/discord-sign-in-2026-10-29.md): Discord brings a username, so its accounts take the
   name step like email (testdata/discord-sign-in/cases.json), and closing the web sheet or Cancel on Discord's
   screen is a cancel, not a bug. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/discord-sign-in/cases.json").standardized

private struct Cases: Decodable {
    struct NeedsName: Decodable { let name: String; let providers: [String]; let first_name: String?; let needs: Bool }
    let needsName: [NeedsName]
}

final class DiscordSignInTests: XCTestCase {
    private let cases = try! JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))

    func testNeedsName() {
        XCTAssertFalse(cases.needsName.isEmpty)
        for c in cases.needsName {
            XCTAssertEqual(SignIn.needsName(providers: c.providers, firstName: c.first_name), c.needs, c.name)
        }
    }

    func testClosingTheSheetOrCancelOnDiscordSaysNothing() {
        XCTAssertEqual(SignIn.Failure(ASWebAuthenticationSessionError(.canceledLogin)), .cancelled)
        XCTAssertEqual(SignIn.Failure(AuthError.pkceGrantCodeExchange(
            message: "The resource owner or authorization server denied the request", error: "access_denied", code: "400"
        )), .cancelled)
        XCTAssertEqual(SignIn.Failure(AuthError.implicitGrantRedirect(message: "access_denied")), .cancelled)
    }

    func testOtherDiscordFailuresAreReported() {
        XCTAssertEqual(SignIn.Failure(ASWebAuthenticationSessionError(.presentationContextNotProvided)), .failed)
        XCTAssertEqual(SignIn.Failure(AuthError.pkceGrantCodeExchange(
            message: "Unable to exchange external code", error: "server_error", code: "500"
        )), .failed)
    }

    func testReturnsToTheAppScheme() {
        XCTAssertEqual(SignIn.discordReturn.absoluteString, "table1://auth-callback")
    }
}
