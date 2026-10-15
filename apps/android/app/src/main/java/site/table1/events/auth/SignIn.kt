package site.table1.events.auth

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import io.github.jan.supabase.auth.SignOutScope
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.Apple
import io.github.jan.supabase.auth.providers.Google
import io.github.jan.supabase.auth.providers.builtin.IDToken
import site.table1.events.BuildConfig
import site.table1.events.T1App
import site.table1.events.data.Repo
import java.security.MessageDigest
import java.util.UUID

object SignIn {
    /** Google: the system account sheet (Credential Manager), no browser hop. */
    suspend fun google(context: Context) {
        val rawNonce = UUID.randomUUID().toString()
        val hashedNonce = MessageDigest.getInstance("SHA-256")
            .digest(rawNonce.toByteArray())
            .joinToString("") { "%02x".format(it) }

        val option = GetGoogleIdOption.Builder()
            .setServerClientId(BuildConfig.GOOGLE_WEB_CLIENT_ID)
            .setFilterByAuthorizedAccounts(false)
            .setNonce(hashedNonce)
            .build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
        val result = CredentialManager.create(context).getCredential(context, request)
        val credential = GoogleIdTokenCredential.createFrom(result.credential.data)

        T1App.supabase.auth.signInWith(IDToken) {
            idToken = credential.idToken
            provider = Google
            nonce = rawNonce
        }
    }

    /** Apple on Android: Supabase OAuth in a Custom Tab, back via table1://auth-callback. */
    suspend fun apple() {
        T1App.supabase.auth.signInWith(Apple)
    }

    suspend fun signOut() {
        T1App.supabase.auth.signOut()
    }

    /** Deletes the account on the server, then drops the session on this device. */
    suspend fun deleteAccount() {
        Repo.deleteAccount()
        runCatching { T1App.supabase.auth.signOut(SignOutScope.LOCAL) }
    }
}
