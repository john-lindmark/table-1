package site.table1.events.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import site.table1.events.util.Telemetry

/* A person is a way to their profile (contract/friends-sharing-2026-10-18.md § Tapping a person). Wherever a player or
   another account is drawn with an account behind it (an avatar, a standings or players row, an opponent's name), a tap
   opens their profile, where Add friend is. Guests (no account) aren't tappable. A row whose own tap does something else
   keeps it; there only the avatar opens the profile.

   AppRoot provides the opener around its NavHost, so the profile pushes on the same back stack and Back returns. */

/** Opens a profile by user id; null where nothing should (previews, galleries). */
val LocalOpenProfile = staticCompositionLocalOf<((String) -> Unit)?> { null }

object PersonLink {
    /** Whose profile a tap opens: null for a guest or an empty id. */
    fun target(userId: String?): String? = userId?.trim()?.takeIf { it.isNotEmpty() }?.lowercase()
}

/** `open(userId)` is the tap that opens their profile, or null when there's nothing to open. `from` names the place. */
@Composable
fun rememberOpenProfile(from: String): (String?) -> (() -> Unit)? {
    val opener = LocalOpenProfile.current
    return { userId ->
        val id = PersonLink.target(userId)
        if (id == null || opener == null) null
        else ({
            Telemetry.capture("person_tapped", mapOf("from" to from))
            opener(id)
        })
    }
}
