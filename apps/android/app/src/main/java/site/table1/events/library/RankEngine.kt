package site.table1.events.library

import android.content.Context
import com.whl.quickjs.android.QuickJSLoader
import com.whl.quickjs.wrapper.QuickJSContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import site.table1.events.BuildConfig
import site.table1.events.util.Telemetry

/* The cube ranking engine as a file the server publishes (contract/cube-rankings-2026-10-21.md § The engine as a file;
 * John, 2026-11-13: "updates to the cube logic don't require new builds and just require a server update").
 *
 * The app's own engine (CubeRanking.kt) carries [CubeRanking.RULES], the date its rules last changed. The server publishes
 * the TypeScript engine (table-1-events-web/src/lib/rankEngine.ts, built by tools/rank-engine/build.mjs) with a manifest
 * naming its rules. When those are newer rules than the app's, rankings opened from then on decide their lists, next
 * screens and estimates in that file, run here in QuickJS on one thread of its own; knowledge, why-chains, picks and
 * comparisons stay native. Otherwise, or when the file is missing, fails its hash or self test, or speaks another `api`,
 * the app uses its own engine: nothing changes for a build that's current. Kept in files/rank-engine, loaded at launch
 * (works offline), the manifest asked for at most hourly when a ranking opens. */

/** Evaluates JavaScript and hands back what it returned (String, Number, Boolean or null). */
interface RankJs {
    fun eval(code: String): Any?
    fun close() {}
}

/** QuickJS, used only from the thread that made it (the wrapper requires it). */
class QuickJsRuntime : RankJs {
    private val thread = Executors.newSingleThreadExecutor { r -> Thread(r, "rank-engine").apply { isDaemon = true } }
    private val ctx: QuickJSContext = thread.submit<QuickJSContext> {
        QuickJSLoader.init()
        QuickJSContext.create().apply { setMaxStackSize(4 * 1024 * 1024) }
    }.get()

    override fun eval(code: String): Any? = thread.submit<Any?> { ctx.evaluate(code) }.get()
    override fun close() { thread.submit { ctx.destroy() }.get(); thread.shutdown() }
}

object RankEngine {
    /** The interface this build speaks (rankEngine.ts `API`). */
    const val API = 1
    /** States the file keeps alive (Kotlin has no deinit): the newest ones; an older one asked again falls back to ours. */
    private const val KEEP = 16

    @Serializable
    data class Manifest(val api: Int, val rules: String, val version: String, val file: String, val sha256: String, val bytes: Int? = null)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = false }
    private val lock = Any()
    private var js: RankJs? = null
    private val handles = ArrayDeque<Int>()
    @Volatile var version: String? = null; private set
    @Volatile private var checkedAt = 0L

    val active: Boolean get() = synchronized(lock) { js != null }

    private fun dir(context: Context) = File(context.filesDir, "rank-engine")
    private val base get() = "${BuildConfig.SUPABASE_URL}/storage/v1/object/public/catalog/engines/rank"

    /** The file's rules are other (newer) rules than the app's own. Dates compare as strings. */
    fun newer(m: Manifest) = m.rules > CubeRanking.RULES

    /** Loads the kept file at launch when its rules are newer than this build's. Call off the main thread. */
    fun start(context: Context) {
        runCatching {
            val m = json.decodeFromString<Manifest>(File(dir(context), "manifest.json").readText())
            if (!newer(m)) return
            val bytes = File(dir(context), m.file).readBytes()
            if (sha256(bytes) == m.sha256.lowercase()) use(m, bytes.decodeToString(), "kept", runtime = ::QuickJsRuntime)
        }
    }

    /** Asks for the manifest (at most hourly unless [force]), downloads a new file, checks its hash and keeps it. Off the
     *  main thread. Offline or an odd answer keeps what's loaded. */
    fun refresh(context: Context, force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!force && now - checkedAt < 3_600_000) return
        checkedAt = now
        runCatching {
            val text = get("$base/manifest.json")?.decodeToString() ?: return
            val m = json.decodeFromString<Manifest>(text)
            val d = dir(context).apply { mkdirs() }
            if (!newer(m)) { File(d, "manifest.json").writeText(text); unload(); return }
            if (version == m.version) return
            val path = File(d, m.file)
            var bytes = if (path.exists()) path.readBytes() else ByteArray(0)
            if (sha256(bytes) != m.sha256.lowercase()) {
                bytes = get("$base/${m.file}") ?: return
                if (sha256(bytes) != m.sha256.lowercase()) {
                    Telemetry.capture("rank_engine_failed", mapOf("why" to "hash", "version" to m.version)); return
                }
                path.writeBytes(bytes)
            }
            File(d, "manifest.json").writeText(text)
            use(m, bytes.decodeToString(), "downloaded", runtime = ::QuickJsRuntime)
        }
    }

    private fun get(url: String): ByteArray? {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000; c.readTimeout = 25_000; c.useCaches = false
        return try { if (c.responseCode == 200) c.inputStream.use { it.readBytes() } else null } finally { c.disconnect() }
    }

    private fun sha256(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    /** Runs [code] as the engine when the manifest's rules are newer than the app's own and it passes its checks.
     *  [force] (tests) loads it whatever its rules. */
    fun use(m: Manifest, code: String, from: String, force: Boolean = false, runtime: () -> RankJs): Boolean {
        if (!force && !newer(m)) { unload(); return false }
        if (m.api != API) { Telemetry.capture("rank_engine_failed", mapOf("why" to "api", "version" to m.version)); unload(); return false }
        val rt = runCatching(runtime).getOrNull() ?: return false
        val ok = runCatching {
            rt.eval(code + "\n;void 0") // nothing back: an object would need releasing
            (rt.eval("T1Rank.api") as? Number)?.toInt() == API && rt.eval("T1Rank.rules") == m.rules && rt.eval("T1Rank.selfTest()") == true
        }.getOrDefault(false)
        if (!ok) {
            Telemetry.capture("rank_engine_failed", mapOf("why" to "self_test", "version" to m.version))
            runCatching { rt.close() }; unload(); return false
        }
        synchronized(lock) { js?.let { runCatching { it.close() } }; js = rt; handles.clear(); version = m.version }
        Telemetry.capture("rank_engine_used", mapOf("version" to m.version, "rules" to m.rules, "from" to from))
        return true
    }

    /** Debug builds (MainActivity `t1RankEngine`): the file at [path] in QuickJS, its self test and how long a ranking
     *  from [argsPath] (rankEngine.ts OpenArgs JSON) takes to open and to lock in final screens. Logcat tag RankEngine. */
    fun debugCheck(path: String, argsPath: String?) {
        val log = { m: String -> android.util.Log.i("RankEngine", m) }
        runCatching {
            val code = File(path).readText()
            val t0 = System.nanoTime()
            val rt = QuickJsRuntime()
            rt.eval(code + "\n;void 0")
            val loaded = (System.nanoTime() - t0) / 1_000_000
            val t1 = System.nanoTime()
            val ok = rt.eval("T1Rank.selfTest()")
            log("loaded in $loaded ms; rules ${rt.eval("T1Rank.rules")}; selfTest $ok in ${(System.nanoTime() - t1) / 1_000_000} ms")
            if (argsPath != null) {
                val args = File(argsPath).readText()
                val t2 = System.nanoTime()
                var h = (rt.eval("T1Rank.open(${lit(args)})") as Number).toInt()
                var q = rt.eval("JSON.stringify(JSON.parse(T1Rank.session($h, 'F')).question)") as String
                log("open + final in ${(System.nanoTime() - t2) / 1_000_000} ms")
                val times = ArrayList<Long>()
                repeat(20) {
                    if (q == "null") return@repeat
                    val t = System.nanoTime()
                    val h2 = (rt.eval("T1Rank.append($h, JSON.stringify({s: 'F', o: $q}))") as Number).toInt()
                    q = rt.eval("JSON.stringify(JSON.parse(T1Rank.session($h2, 'F')).question)") as String
                    rt.eval("T1Rank.free($h)"); h = h2
                    times += (System.nanoTime() - t) / 1_000_000
                }
                times.sort()
                if (times.isNotEmpty()) log("lock-in median ${times[times.size / 2]} ms, max ${times.last()} ms (${times.size})")
            }
            rt.close()
        }.onFailure { log("failed: $it") }
    }

    fun unload() = synchronized(lock) { js?.let { runCatching { it.close() } }; js = null; handles.clear(); version = null }

    /** A JS string literal of [s] (JSON is valid JavaScript). */
    private fun lit(s: String) = Json.encodeToString(s)

    internal fun call(code: String): Any? = synchronized(lock) {
        val rt = js ?: return null
        runCatching { rt.eval(code) }.getOrElse {
            Telemetry.capture("rank_engine_failed", mapOf("why" to "call", "message" to (it.message ?: "").take(200))); null
        }
    }

    private fun keep(h: Int) = synchronized(lock) {
        handles.addLast(h)
        while (handles.size > KEEP) { val old = handles.removeFirst(); runCatching { js?.eval("T1Rank.free($old)") } }
    }

    @Serializable private data class OpenArgs(val id: String, val cards: Map<String, String>, val log: List<RankScreen>, val depth: String, val top: Int, val fresh: List<String>)

    /** A ranking in the file, or null when the app's own engine decides. */
    fun open(rankingId: String, category: Map<String, RankJob>, log: List<RankScreen>, depth: String, top: Int, fresh: Set<String>): RankEngineState? {
        if (!active) return null
        val args = json.encodeToString(OpenArgs(rankingId, category.mapValues { it.value.key }, log, depth, top, fresh.sorted()))
        val h = (call("T1Rank.open(${lit(args)})") as? Number)?.toInt() ?: return null
        keep(h)
        return RankEngineState(h)
    }

    internal fun append(handle: Int, screen: RankScreen): RankEngineState? {
        val h = (call("T1Rank.append($handle, ${lit(json.encodeToString(screen))})") as? Number)?.toInt() ?: return null
        keep(h)
        return RankEngineState(h)
    }

    @Serializable internal data class Wire(val top: List<String>, val done: Boolean, val target: Int, val size: Int, val question: List<String>? = null,
                                           val pinned: List<String>, val open: List<String>, val waiting: List<String>, val check: Boolean, val checked: Int)

    internal fun session(handle: Int, job: RankJob): Wire? =
        (call("T1Rank.session($handle, ${lit(job.key)})") as? String)?.let { runCatching { json.decodeFromString<Wire>(it) }.getOrNull() }

    internal fun expected(handle: Int, job: RankJob): Int? = (call("T1Rank.expected($handle, ${lit(job.key)})") as? Number)?.toInt()
}

/** One ranking state inside the file, and the sessions already asked for. */
class RankEngineState internal constructor(val handle: Int) {
    private val sessions = HashMap<RankJob, RankSession>()

    fun appending(screen: RankScreen): RankEngineState? = RankEngine.append(handle, screen)

    /** The file's session mapped onto the native knowledge's indexes (both index cards by sorted oracle id). */
    fun session(job: RankJob, K: RankKnowledge): RankSession? = synchronized(sessions) {
        sessions[job]?.let { return it }
        val w = RankEngine.session(handle, job) ?: return null
        fun ix(ids: List<String>): List<Int>? = ids.map { K.indexOf(it) ?: return null }
        val top = ix(w.top) ?: return null
        val pinned = ix(w.pinned) ?: return null
        val waiting = ix(w.waiting) ?: return null
        val open = RankBits(K.size).also { b -> (ix(w.open) ?: return null).forEach(b::add) }
        val question = w.question?.let { ix(it) ?: return null }
        RankSession(top, w.done, w.target, w.size, question, pinned, open, waiting, w.check, w.checked).also { sessions[job] = it }
    }

    fun expected(job: RankJob): Int? = RankEngine.expected(handle, job)
}
