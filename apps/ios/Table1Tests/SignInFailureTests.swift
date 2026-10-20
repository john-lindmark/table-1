import AuthenticationServices
import XCTest
@testable import Table1

/* How a sign-in sheet ended. ASAuthorizationError 1000 (unknown) reached Sentry as a bug from three TestFlight users
   (TABLE-1-IOS-3, 2026-10-20): it's Apple's sheet giving up on the device (no Apple Account, Screen Time), so it's
   shown and counted but not reported. Real failures still are. */

final class SignInFailureTests: XCTestCase {
    func testAppleUnknownIsUnavailableNotABug() {
        let f = SignIn.Failure(ASAuthorizationError(.unknown))
        XCTAssertEqual(f, .appleUnavailable)
        XCTAssertEqual(f.reason, "apple_unavailable")
        XCTAssertNotNil(f.message)
        XCTAssertEqual(SignIn.Failure(ASAuthorizationError(.notInteractive)), .appleUnavailable)
    }

    func testCancelsSayNothing() {
        XCTAssertEqual(SignIn.Failure(ASAuthorizationError(.canceled)), .cancelled)
        XCTAssertEqual(SignIn.Failure(NSError(domain: "com.google.GIDSignIn", code: -5)), .cancelled)
        XCTAssertNil(SignIn.Failure.cancelled.message)
    }

    func testEverythingElseIsReported() {
        XCTAssertEqual(SignIn.Failure(ASAuthorizationError(.failed)), .failed)
        XCTAssertEqual(SignIn.Failure(ASAuthorizationError(.invalidResponse)), .failed)
        XCTAssertEqual(SignIn.Failure(NSError(domain: "com.google.GIDSignIn", code: -1)), .failed)
        XCTAssertEqual(SignIn.Failure(SignIn.SignInError.missingToken), .failed)
        XCTAssertEqual(SignIn.Failure(URLError(.notConnectedToInternet)), .failed)
    }
}
