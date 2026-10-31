package site.table1.events.util

import io.github.jan.supabase.exceptions.HttpRequestException
import io.ktor.client.network.sockets.ConnectTimeoutException
import io.ktor.client.network.sockets.SocketTimeoutException
import io.ktor.client.plugins.HttpRequestTimeoutException
import kotlinx.coroutines.CancellationException
import site.table1.events.T1App
import site.table1.events.library.CollectionOp
import java.io.File
import java.io.IOException

/**
 * Offline rules shared with iOS and web (contract/offline-2026-10-31.md, cases testdata/offline/cases.json): how long
 * ago a saved answer is, what a screen says when a call fails, and which failed collection batches wait in the outbox.
 */
object Offline {
    /** "just now", "3 min ago", "2 h ago", "1 day ago". */
    fun ago(seconds: Long): String = when {
        seconds < 60 -> "just now"
        seconds < 3600 -> "${seconds / 60} min ago"
        seconds < 86400 -> "${seconds / 3600} h ago"
        else -> (seconds / 86400).let { if (it == 1L) "1 day ago" else "$it days ago" }
    }

    /** What a screen says after its call fails (text to whether it's an error): nothing when it didn't; the saved
     *  answer's age as a plain notice when there is one; else the error itself. */
    fun notice(failed: Boolean, savedAgo: Long?, error: String?): Pair<String, Boolean>? {
        if (!failed) return null
        if (savedAgo != null) return "Couldn't refresh · last updated ${ago(savedAgo)}" to false
        val e = error?.trim().orEmpty()
        return (e.ifEmpty { "Couldn't load. Check your connection." }) to true
    }

    /** Seconds since [atMs], for [notice]. */
    fun age(atMs: Long?, now: Long = System.currentTimeMillis()): Long? = atMs?.let { maxOf(0L, (now - it) / 1000) }

    /** A failure to reach the server (offline, timed out, connection dropped), as opposed to its answer. */
    fun isNetwork(e: Throwable): Boolean {
        if (e is CancellationException) return false
        var t: Throwable? = e
        var depth = 0
        while (t != null && depth < 5) {
            if (t is HttpRequestException || t is HttpRequestTimeoutException || t is ConnectTimeoutException ||
                t is SocketTimeoutException || t is IOException) return true
            t = t.cause
            depth++
        }
        return false
    }

    /** A failed collection_apply batch waits in the outbox when the failure was the network and every op only adds. */
    fun queues(ops: List<CollectionOp>, network: Boolean): Boolean =
        network && ops.isNotEmpty() && ops.all { (it.delta ?: 0) > 0 && it.qty == null }

    /** The copies the outbox will add per item key, so a sync row shows the server's count plus them. */
    fun deltas(batches: List<List<CollectionOp>>): Map<String, Int> {
        val out = HashMap<String, Int>()
        for (ops in batches) for (op in ops) out.merge(op.key, op.delta ?: 0, Int::plus)
        return out.filterValues { it != 0 }
    }
}

/**
 * The last answers to a few calls, kept per account as they came off the wire (contract/offline-2026-10-31.md § 1), so
 * the Events tab, an event and Insights open on what was last seen when the server can't be reached. The file's
 * modification time is when it was fetched. Call off the main thread.
 */
object OfflineCache {
    private fun file(user: String, key: String) =
        File(File(T1App.instance.filesDir, "offline/$user").apply { mkdirs() }, key.replace('/', '_') + ".json")

    /** The saved text and when it was fetched (ms), or null. */
    fun load(user: String, key: String): Pair<String, Long>? = runCatching {
        val f = file(user, key)
        if (!f.exists()) null else f.readText() to f.lastModified()
    }.getOrNull()

    fun save(user: String, key: String, text: String) {
        runCatching {
            val f = file(user, key)
            val tmp = File(f.path + ".tmp")
            tmp.writeText(text)
            tmp.renameTo(f)
            f.setLastModified(System.currentTimeMillis())
        }
    }
}
