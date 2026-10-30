package site.table1.events.library

import site.table1.events.util.rethrowIfCancelled

import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.ui.components.parseInstant
import site.table1.events.util.Telemetry

/* Following someone else's binder, deck or cube (contract/follows-2026-10-25.md). The server groups changes into
   updates (quiet 30 minutes, at most one every 6 hours); this keeps the Following list, each item's follow state and
   its Changes. Rules shared with iOS and web in testdata/follows/cases.json. Android has no push yet (FCM), so the
   Following list is where updates show. */

@Serializable
data class FollowUpdateSummary(val at: String, val added: Int, val removed: Int)

@Serializable
data class FollowState(
    val following: Boolean = false,
    val push: Boolean = true,
    val unseen: Int = 0,
    @SerialName("last_update") val lastUpdate: FollowUpdateSummary? = null,
)

@Serializable
data class FollowOwner(@SerialName("display_name") val displayName: String, @SerialName("avatar_url") val avatarUrl: String? = null)

/** One row of follows_list. Unavailable rows carry only kind, id, push and followed_at. */
@Serializable
data class Follow(
    val kind: String,
    val id: String,
    val available: Boolean,
    val push: Boolean,
    @SerialName("followed_at") val followedAt: String,
    val unseen: Int = 0,
    val name: String? = null,
    val format: String? = null,
    @SerialName("for_trade") val forTrade: Boolean? = null,
    val cards: Int? = null,
    val owner: FollowOwner? = null,
    /** Reaches you on their profile: open it there. */
    @SerialName("user_id") val userId: String? = null,
    /** Reaches you through the link you followed with: open the link. */
    val token: String? = null,
    @SerialName("last_update") val lastUpdate: FollowUpdateSummary? = null,
) {
    val title get() = if (available) name ?: "Untitled" else "A $kind you followed"
    val subtitle get() = listOfNotNull(kind.replaceFirstChar { it.uppercase() }, owner?.displayName).joinToString(" · ")

    /** Where it opens: its profile section, or the link it was followed through. */
    val route: String? get() = when {
        !available -> null
        token != null -> "collection/shared/$token"
        userId != null -> "profile/$userId/$kind/$id"
        else -> null
    }
}

/** One card in an update: [qty] > 0 added, < 0 taken out. [board] is the deck section (cubes "main", binders null). */
data class FollowCard(val cardId: String, val board: String?, val qty: Int)

@Serializable
data class FollowUpdateWire(val at: String, val added: Int, val removed: Int, val cards: List<JsonArray>) {
    fun cards(): List<FollowCard> = cards.mapNotNull { r ->
        val id = (r.getOrNull(0) as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
        val board = (r.getOrNull(1) as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull
        FollowCard(id, board, (r.getOrNull(2) as? JsonPrimitive)?.intOrNull ?: 0)
    }
}

@Serializable
data class FollowChanges(val kind: String, val id: String, val name: String? = null, val updates: List<FollowUpdateWire>)

@Serializable
private data class FollowsList(val items: List<Follow>)

object Follows {
    const val MINUS = "−"

    /** "just now" · "N min ago" · "N h ago" · "N d ago" (under 30 days) · "N mo ago". */
    fun ago(seconds: Double): String {
        val s = maxOf(0L, seconds.toLong())
        if (s < 60) return "just now"
        if (s < 3600) return "${s / 60} min ago"
        if (s < 86400) return "${s / 3600} h ago"
        val d = s / 86400
        return if (d < 30) "$d d ago" else "${d / 30} mo ago"
    }

    /** "+12 −8", "+3", "−2". */
    fun change(added: Int, removed: Int) =
        listOfNotNull(if (added > 0) "+$added" else null, if (removed > 0) "$MINUS$removed" else null).joinToString(" ")

    fun since(u: FollowUpdateSummary, nowMs: Long): String {
        val at = parseInstant(u.at) ?: nowMs
        return "${change(u.added, u.removed)} · ${ago((nowMs - at) / 1000.0)}"
    }

    /** A Following row's detail line. */
    fun detail(f: Follow, nowMs: Long): String {
        if (!f.available) return "This isn't available"
        val line = f.lastUpdate?.let { since(it, nowMs) } ?: "No changes yet"
        return if (f.push) line else "$line · pushes off"
    }

    /** The Library home row: "3 followed · 1 updated". */
    fun home(items: List<Follow>): String {
        val updated = items.count { it.available && it.unseen > 0 }
        return "${items.size} followed" + if (updated > 0) " · $updated updated" else ""
    }

    /** An update's cards as Added and Taken out, biggest first, then by card id ([FollowCard.qty] positive in both). */
    fun sections(cards: List<FollowCard>): Pair<List<FollowCard>, List<FollowCard>> {
        val order = compareByDescending<FollowCard> { it.qty }.thenBy { it.cardId }.thenBy { it.board ?: "" }
        return cards.filter { it.qty > 0 }.sortedWith(order) to cards.filter { it.qty < 0 }.map { it.copy(qty = -it.qty) }.sortedWith(order)
    }
}

data class FollowsState(val items: List<Follow>? = null, val states: Map<String, FollowState> = emptyMap(), val error: String? = null)

object FollowsStore {
    private val _state = MutableStateFlow(FollowsState())
    val state: StateFlow<FollowsState> = _state.asStateFlow()
    private val rpc get() = T1App.supabase.postgrest

    fun stop() { _state.value = FollowsState() }

    /** Loads follows_list; returns it (null when it failed). */
    suspend fun load(): List<Follow>? =
        runCatching { rpc.rpc("follows_list").decodeAs<FollowsList>().items }
            .onSuccess { l -> _state.update { it.copy(items = l, error = null) } }
            .onFailure { e -> e.rethrowIfCancelled(); _state.update { it.copy(error = e.message) } }
            .getOrNull()

    suspend fun loadState(kind: String, id: String) {
        runCatching { rpc.rpc("follow_get", buildJsonObject { put("p_kind", kind); put("p_id", id) }).decodeAs<FollowState>() }
            .onSuccess { s -> _state.update { it.copy(states = it.states + (id to s)) } }
            .onFailure { e -> e.rethrowIfCancelled(); _state.update { it.copy(error = e.message) } }
    }

    /** Follow / unfollow, or pushes on / off ([push] null keeps it). [token]: the link being looked through. */
    suspend fun set(kind: String, id: String, follow: Boolean, push: Boolean? = null, token: String? = null, from: String) {
        val s = rpc.rpc("follow_set", buildJsonObject {
            put("p_kind", kind); put("p_id", id); put("p_follow", follow)
            if (push == null) put("p_push", JsonNull) else put("p_push", push)
            if (token == null) put("p_token", JsonNull) else put("p_token", token)
        }).decodeAs<FollowState>()
        _state.update { it.copy(states = it.states + (id to s)) }
        Telemetry.capture("follow_changed", mapOf("kind" to kind, "following" to s.following, "push" to s.push, "from" to from))
        load()
    }

    /** The updates since you followed; opening them marks them seen. */
    suspend fun changes(kind: String, id: String): FollowChanges {
        val c = rpc.rpc("follow_changes", buildJsonObject { put("p_kind", kind); put("p_id", id) }).decodeAs<FollowChanges>()
        _state.update { st ->
            st.copy(states = st.states[id]?.let { st.states + (id to it.copy(unseen = 0)) } ?: st.states,
                    items = st.items?.map { if (it.id == id) it.copy(unseen = 0) else it })
        }
        Telemetry.capture("follow_changes_viewed", mapOf("kind" to kind, "updates" to c.updates.size))
        return c
    }
}
