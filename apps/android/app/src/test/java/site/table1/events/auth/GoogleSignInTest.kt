package site.table1.events.auth

import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialCustomException
import androidx.credentials.exceptions.GetCredentialProviderConfigurationException
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.exceptions.NoCredentialException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import site.table1.events.auth.SignIn.GoogleFailure

/* Google's sheet fails before Supabase is called, so the app has to say why (2026-10-29). */
class GoogleSignInTest {
    @Test fun cancelSaysNothing() {
        val f = GoogleFailure.of(GetCredentialCancellationException("closed"))
        assertEquals(GoogleFailure.Cancelled, f)
        assertNull(f.message)
    }

    @Test fun unregisteredSigningKeyIsNotSetUp() {
        // What Play Services says when the build's SHA-1 has no Android OAuth client.
        assertEquals(GoogleFailure.NotSetUp, GoogleFailure.of(GetCredentialCustomException("com.google.android.libraries.identity.googleid.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL", "[28444] Developer console is not set up correctly.")))
        assertEquals(GoogleFailure.NotSetUp, GoogleFailure.of(GetCredentialUnknownException("[10] ")))
        assertEquals(GoogleFailure.NotSetUp, GoogleFailure.of(NoCredentialException("[10] Developer error")))
    }

    @Test fun otherFailures() {
        assertEquals(GoogleFailure.NoAccount, GoogleFailure.of(NoCredentialException("No credentials available")))
        assertEquals(GoogleFailure.NoProvider, GoogleFailure.of(GetCredentialProviderConfigurationException("no provider")))
        assertEquals(GoogleFailure.Failed, GoogleFailure.of(GetCredentialUnknownException("timeout")))
        assertEquals(GoogleFailure.Failed, GoogleFailure.of(IllegalStateException("x")))
    }

    @Test fun detailCarriesTypeAndCode() {
        val d = GoogleFailure.detail(GetCredentialUnknownException("[28444] Developer console is not set up correctly."))
        assertEquals("28444", d["code"])
        assertEquals("TYPE_UNKNOWN", d["type"])
        assertEquals(emptyMap<String, Any>(), GoogleFailure.detail(IllegalStateException("plain")))
    }
}
