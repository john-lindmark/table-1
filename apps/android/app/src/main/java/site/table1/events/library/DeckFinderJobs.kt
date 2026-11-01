package site.table1.events.library

import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import site.table1.events.T1App
import site.table1.events.ui.components.parseInstant
import java.time.Instant

/**
 * Deck finder jobs (contract/deck-finder-2026-10-15.md § Jobs): a search runs on the server as a job, so the phone
 * can be locked; the screen polls the job and a `deck.found` push brings the player back to it. Rules shared with
 * iOS and the web in testdata/deck-finder/cases.json (DeckFinderTest).
 */
@Serializable
data class FinderAnswer(val question: String, val answer: String)

/** One search job as `deck_finder_job` returns it. */
@Serializable
data class FinderJob(
    val job_id: String,
    val status: String,
    val query: String = "",
    val format: String? = null,
    val answers: List<FinderAnswer> = emptyList(),
    val result: FinderResult? = null,
    /** What the agent has done so far, in order, for the screen to show while it runs. */
    val steps: List<String> = emptyList(),
    val created_at: String = "",
    val finished_at: String? = null,
) {
    val finished get() = status == "done" || status == "failed"
}

object DeckFinderJobs {
    /** How often the screen asks after a running job, in ms. */
    const val POLL_MS = 3000L
    const val COULD_NOT_FINISH = "The deck finder couldn't finish that search. Try again."

    /**
     * Whether Find a deck, opened with no job of its own, shows the account's newest job: a search still running is
     * picked up, and one that finished in the last hour (a locked phone's search) is shown.
     */
    fun resume(status: String, finishedSecondsAgo: Double?): Boolean {
        if (status == "queued" || status == "running") return true
        return finishedSecondsAgo != null && finishedSecondsAgo < 3600
    }

    fun resume(job: FinderJob, now: Instant = Instant.now()): Boolean =
        resume(job.status, job.finished_at?.let { parseInstant(it) }?.let { ms -> (now.toEpochMilli() - ms) / 1000.0 })

    /** The line under a found deck's name: placement · event · date, whichever are known. */
    fun headline(placement: String, event: String, date: String) = listOf(placement, event, date).filter { it.isNotBlank() }.joinToString(" · ")

    /** The result a finished job shows (a failure with no result still says so). */
    fun resultOf(job: FinderJob) = job.result ?: FinderResult(status = "error", message = COULD_NOT_FINISH)

    @Serializable
    private data class Started(val job_id: String, val status: String = "queued")

    /** Starts a search; the job id to poll. Throws with the server's words when refused (the day's allowance). */
    suspend fun start(query: String, format: String, answers: List<FinderAnswer>): String =
        T1App.supabase.postgrest.rpc("deck_finder_start", buildJsonObject {
            put("p_query", query); put("p_format", format)
            putJsonArray("p_answers") { answers.forEach { a -> addJsonObject { put("question", a.question); put("answer", a.answer) } } }
        }).decodeAs<Started>().job_id

    /** One of your jobs, or with no id the newest of the last 24 hours; null when there is none. */
    suspend fun job(id: String?): FinderJob? {
        val raw = T1App.supabase.postgrest.rpc("deck_finder_job", buildJsonObject { if (id == null) put("p_id", JsonNull) else put("p_id", id) }).data
        if (raw.isBlank() || raw.trim() == "null") return null
        return T1App.json.decodeFromString(FinderJob.serializer(), raw)
    }

    /** What a refused start says: the server's own message (allowance, sign-in), else a plain line. */
    fun words(e: Throwable): String {
        val m = e.message ?: return "The deck finder couldn't search just now. Try again."
        return Regex("\"message\"\\s*:\\s*\"([^\"]+)\"").find(m)?.groupValues?.get(1) ?: m
    }
}
