package site.table1.events.auth

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.jan.supabase.auth.OtpType
import io.github.jan.supabase.auth.SignOutScope
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.Apple
import io.github.jan.supabase.auth.providers.Google
import io.github.jan.supabase.auth.providers.builtin.IDToken
import io.github.jan.supabase.auth.providers.builtin.OTP
import io.github.jan.supabase.auth.user.UserInfo
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import site.table1.events.BuildConfig
import site.table1.events.T1App
import site.table1.events.data.Repo
import java.security.MessageDigest
import java.util.UUID

object SignIn {
    /** False until a real web client ID is in gradle.properties; the button stays hidden until then. */
    val googleConfigured: Boolean
        get() = BuildConfig.GOOGLE_WEB_CLIENT_ID.endsWith(".apps.googleusercontent.com") &&
            !BuildConfig.GOOGLE_WEB_CLIENT_ID.startsWith("REPLACE_")

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

    /** Email: one message with a link and the same one-time code. New addresses get an account. */
    suspend fun sendEmailCode(email: String) {
        T1App.supabase.auth.signInWith(OTP) {
            this.email = email
            createUser = true
        }
    }

    /** The code typed from the email. */
    suspend fun verifyEmailCode(email: String, code: String) {
        T1App.supabase.auth.verifyEmailOtp(type = OtpType.Email.EMAIL, email = email, token = code)
    }

    /** The email's link, https://table-1.site/auth/confirm?token_hash=…&type=email, opened as an app link. */
    fun emailLinkHash(uri: Uri?): String? =
        uri?.takeIf { it.host == "table-1.site" && it.path?.startsWith("/auth/confirm") == true }
            ?.getQueryParameter("token_hash")?.takeIf { it.isNotEmpty() }

    /** Why the email's link didn't sign in (used or expired); shown on the sign-in screen. */
    var emailLinkError by mutableStateOf<String?>(null)

    suspend fun verifyEmailLink(tokenHash: String) {
        emailLinkError = null
        try {
            T1App.supabase.auth.verifyEmailOtp(type = OtpType.Email.EMAIL, tokenHash = tokenHash)
        } catch (e: Exception) {
            emailLinkError = "That sign-in link has expired or was already used. Send a new one."
        }
    }

    /** Email accounts start without a name; one is required before the app opens. Apple and Google bring theirs. */
    fun needsName(user: UserInfo?): Boolean {
        val ids = user?.identities.orEmpty()
        if (user == null || ids.isEmpty() || !ids.all { it.provider == "email" }) return false
        val first = (user.userMetadata?.get("first_name") as? JsonPrimitive)?.contentOrNull
        return first.isNullOrBlank()
    }

    /** First and last name: kept on the account and shown in events as "First Last". */
    suspend fun saveName(first: String, last: String) {
        val f = first.trim()
        val l = last.trim()
        val full = "$f $l"
        Repo.setDisplayName(full)
        T1App.supabase.auth.updateUser {
            data {
                put("first_name", f)
                put("last_name", l)
                put("full_name", full)
            }
        }
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
