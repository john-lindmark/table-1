package site.table1.events.library

import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.postgrest
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled

/* Moderation (contract/moderation-2026-10-18.md): what Table 1 changed on your content and why, with one appeal per
   change; and, for moderators, the review queue. The server decides everything; this store only shows it and sends
   answers back. Same as iOS Moderation.swift. */

@Serializable
data class ModerationMe(val moderator: Boolean = false, val unseen: Int = 0, @SerialName("restricted_until") val restrictedUntil: String? = null)

@Serializable
data class ModerationNotice(
    val id: Long, @SerialName("subject_kind") val subjectKind: String, val label: String, val action: String,
    val category: String? = null, @SerialName("reason_text") val reasonText: String, val at: String, val seen: Boolean = false,
    val appeal: String = "none", @SerialName("can_appeal") val canAppeal: Boolean = false,
) {
    val whatChanged get() = when (action) {
        "reset_name" -> "Changed to a neutral name"
        "clear_handle", "remove_avatar" -> "Removed"
        "unshare" -> "No longer shared"
        "rename_event" -> "Renamed with the event code"
        "rename_guest" -> "Renamed by seat"
        "hide_photo" -> "Hidden from other players"
        "clear_note" -> "Cleared"
        else -> "Changed"
    }

    val status get() = when (appeal) {
        "open" -> "Appeal sent"; "reverted" -> "Restored"; "upheld" -> "Upheld"; else -> if (seen) "" else "New"
    }
}

@Serializable
data class ReviewCheck(
    val id: Long, @SerialName("subject_kind") val subjectKind: String, val text: String? = null, val bucket: String? = null,
    val path: String? = null, val status: String, val category: String? = null, val reason: String? = null, val source: String = "write",
    val enforced: Boolean = false, val owner: Person? = null, val strikes: Int = 0, val reports: Int = 0,
)

@Serializable
data class ReviewAppeal(
    val id: Long, val label: String, val action: String, val category: String? = null, val note: String? = null,
    val owner: Person? = null, val text: String? = null, val path: String? = null, val bucket: String? = null,
)

@Serializable
data class FlaggedAccount(
    @SerialName("user_id") val userId: String, @SerialName("display_name") val displayName: String, val handle: String? = null,
    val strikes: Int = 0, val reporters: Int = 0, @SerialName("restricted_until") val restrictedUntil: String? = null,
)

@Serializable
data class ReviewQueue(val mode: String = "shadow", val checks: List<ReviewCheck> = emptyList(), val appeals: List<ReviewAppeal> = emptyList(),
                       val flagged: List<FlaggedAccount> = emptyList()) {
    val waiting get() = checks.size + appeals.size + flagged.size
}

object ModerationWords {
    fun subject(kind: String) = when (kind) {
        "display_name" -> "Display name"; "handle" -> "Handle"; "avatar" -> "Profile photo"; "list_name" -> "Deck or cube name"
        "binder_name" -> "Binder name"; "event_name" -> "Event name"; "guest_name" -> "Guest name"; "deck_photo" -> "Deck photo"
        "deck_photo_note" -> "Deck photo note"; else -> kind
    }

    fun category(c: String?) = when (c ?: "") {
        "hate" -> "Hate"; "harassment" -> "Harassment"; "sexual" -> "Sexual"; "child_safety" -> "Child safety"
        "violence" -> "Violence"; "self_harm" -> "Self-harm"; "spam" -> "Spam"; "personal_info" -> "Personal info"
        "impersonation" -> "Impersonation"; "" -> "Unclear"; else -> "Other"
    }

    /** "Oct 18, 2026" from an ISO timestamp. */
    fun date(iso: String?): String? = iso?.let {
        runCatching { java.time.OffsetDateTime.parse(it).toLocalDate() }.getOrNull()
            ?.format(java.time.format.DateTimeFormatter.ofPattern("MMM d, yyyy"))
    }
}

data class ModerationState(val me: ModerationMe? = null, val notices: List<ModerationNotice>? = null, val queue: ReviewQueue? = null,
                           val error: String? = null)

object ModerationStore {
    private val _state = MutableStateFlow(ModerationState())
    val state: StateFlow<ModerationState> = _state.asStateFlow()
    private val rpc get() = T1App.supabase.postgrest

    fun stop() { _state.value = ModerationState() }

    private fun fail(e: Throwable) { e.rethrowIfCancelled(); _state.update { it.copy(error = e.message) } }

    suspend fun loadMe() {
        runCatching { rpc.rpc("moderation_me").decodeAs<ModerationMe>() }.onSuccess { m -> _state.update { it.copy(me = m) } }
            .onFailure { it.rethrowIfCancelled() }
    }

    suspend fun loadNotices() {
        runCatching { rpc.rpc("moderation_notices").decodeAs<List<ModerationNotice>>() }
            .onSuccess { n -> _state.update { it.copy(notices = n, error = null) } }.onFailure(::fail)
    }

    suspend fun markSeen() {
        val s = _state.value
        if ((s.me?.unseen ?: 0) == 0 && s.notices?.any { !it.seen } != true) return
        runCatching { rpc.rpc("moderation_notices_seen") }.onFailure { it.rethrowIfCancelled() }
        loadMe()
    }

    suspend fun appeal(id: Long, note: String) {
        val trimmed = note.trim().take(500)
        rpc.rpc("moderation_appeal", buildJsonObject {
            put("p_action_id", id)
            if (trimmed.isEmpty()) put("p_note", JsonNull) else put("p_note", trimmed)
        })
        Telemetry.capture("moderation_appealed")
        loadNotices()
    }

    suspend fun loadQueue() {
        runCatching { rpc.rpc("moderation_queue", buildJsonObject { put("p_limit", 100) }).decodeAs<ReviewQueue>() }
            .onSuccess { q -> _state.update { it.copy(queue = q, error = null) } }.onFailure(::fail)
    }

    suspend fun resolve(check: ReviewCheck, decision: String) {
        rpc.rpc("moderation_resolve", buildJsonObject { put("p_check_id", check.id); put("p_decision", decision) })
        Telemetry.capture("moderation_resolved", mapOf("decision" to decision, "subject" to check.subjectKind))
        loadQueue()
    }

    @Serializable private data class AppealResolved(@SerialName("delete_path") val deletePath: String? = null)

    suspend fun resolveAppeal(appeal: ReviewAppeal, decision: String) {
        val r = rpc.rpc("moderation_appeal_resolve", buildJsonObject { put("p_action_id", appeal.id); put("p_decision", decision) })
            .decodeAs<AppealResolved>()
        // An upheld profile photo: the file goes too.
        r.deletePath?.let { path -> runCatching { T1App.supabase.functions.invoke("moderate", buildJsonObject { put("purge", path) }) } }
        Telemetry.capture("moderation_resolved", mapOf("decision" to decision, "subject" to "appeal"))
        loadQueue()
    }

    suspend fun restrict(userId: String, days: Int, reason: String) {
        rpc.rpc("moderation_restrict", buildJsonObject {
            put("p_user_id", userId); put("p_days", days)
            if (reason.isEmpty()) put("p_reason", JsonNull) else put("p_reason", reason)
        })
        Telemetry.capture("moderation_resolved", mapOf("decision" to if (days == 0) "lift" else "restrict", "subject" to "account"))
        loadQueue()
    }

    suspend fun setMode(mode: String) {
        rpc.rpc("moderation_set_mode", buildJsonObject { put("p_mode", mode) })
        loadQueue()
    }

    @Serializable private data class Signed(val urls: Map<String, String> = emptyMap())

    /** Short-lived links to the photos under review (the `moderate` function signs them for moderators). */
    suspend fun photoUrls(items: List<Pair<String, String>>): Map<String, String> {
        if (items.isEmpty()) return emptyMap()
        return runCatching {
            val r = T1App.supabase.functions.invoke("moderate", buildJsonObject {
                put("sign", buildJsonArray { items.forEach { (b, p) -> add(buildJsonObject { put("bucket", b); put("path", p) }) } })
            })
            T1App.json.decodeFromString<Signed>(r.bodyAsText()).urls
        }.onFailure { it.rethrowIfCancelled() }.getOrDefault(emptyMap())
    }
}
