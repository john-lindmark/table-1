package site.table1.events

import android.app.Application
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.realtime.Realtime
import io.github.jan.supabase.serializer.KotlinXSerializer
import io.github.jan.supabase.storage.Storage
import kotlinx.serialization.json.Json

/** One Supabase client for the whole app; the session persists across launches. */
class T1App : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    companion object {
        lateinit var instance: T1App
            private set

        val json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            explicitNulls = false
        }

        val supabase: SupabaseClient by lazy {
            createSupabaseClient(
                supabaseUrl = BuildConfig.SUPABASE_URL,
                supabaseKey = BuildConfig.SUPABASE_ANON_KEY,
            ) {
                defaultSerializer = KotlinXSerializer(json)
                install(Auth) {
                    // Sign in with Apple returns via table1://auth-callback (see AndroidManifest).
                    scheme = "table1"
                    host = "auth-callback"
                }
                install(Postgrest)
                install(Realtime)
                install(Functions)
                install(Storage)
            }
        }
    }
}
