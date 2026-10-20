import XCTest
@testable import Table1

/* Apple and Google sign-in nonces. The provider puts `hashed` in the ID token; Supabase gets `raw` and refuses the
   token unless the token's nonce is SHA-256(raw) in lowercase hex ("Passed nonce and nonce in id_token should either
   both exist or not" when Google's token carried a nonce the app never sent, 2026-10-20). */

final class SignInNonceTests: XCTestCase {
    func testHashedIsLowercaseHexSHA256OfRaw() {
        // The check Supabase Auth makes: fmt.Sprintf("%x", sha256.Sum256([]byte(raw))) == token nonce.
        XCTAssertEqual(SignIn.Nonce(raw: "abc").hashed,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testEachSignInGetsAFreshNonce() {
        let a = SignIn.Nonce(), b = SignIn.Nonce()
        XCTAssertEqual(a.raw.count, 32)
        XCTAssertNotEqual(a.raw, b.raw)
        XCTAssertEqual(a.hashed, SignIn.Nonce(raw: a.raw).hashed)
    }
}
