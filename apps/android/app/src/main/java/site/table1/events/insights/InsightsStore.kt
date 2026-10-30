package site.table1.events.insights

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * The Insights tab's data (contract/insights-2026-10-24.md): the published pack index, the packs themselves (kept on
 * the device and refetched only when their version changes) and what the viewer picked, remembered on the device.
 * Archetype and card pages come from their RPCs on demand.
 */
object InsightsStore {
    private val json = Json { ignoreUnknownKeys = true }
    private val prefs get() = T1App.instance.getSharedPreferences("insights", Context.MODE_PRIVATE)

    var index by mutableStateOf<List<IndexEntry>>(emptyList()); private set
    var constructed by mutableStateOf<Map<String, ConstructedPack>>(emptyMap()); private set
    var limited by mutableStateOf<Map<String, LimitedPack>>(emptyMap()); private set
    var error by mutableStateOf<String?>(null); private set
    var loading by mutableStateOf(false); private set
    private var loadedAt = 0L
    /** Debug demo: packs and pages from the debug assets, nothing from the network. */
    var demo = false; private set
    private var demoPages: Map<String, String> = emptyMap()
    /** Sets and Arena cube versions to rank (limited_rankable); loaded with Limited. */
    var rankable by mutableStateOf<List<site.table1.events.library.RankableSet>>(emptyList()); private set
    /** New in Insights pushes on for the account; null until loaded. */
    var alerts by mutableStateOf<Boolean?>(null); private set

    @kotlinx.serialization.Serializable private data class On(val on: Boolean)

    /** Limited's extras: the sets to rank and the New in Insights switch; quietly left as they were when they can't load. */
    suspend fun loadExtras() {
        if (demo) {
            if (rankable.isEmpty()) rankable = listOf(
                site.table1.events.library.RankableSet("FRA", "Foundations Remastered", "2026-09-23", "set", 281, pack = true, rankings = 1),
                site.table1.events.library.RankableSet("NHZ", "New Horizons", java.time.LocalDate.now().plusDays(5).toString(), "set", 264, pack = false),
                site.table1.events.library.RankableSet("PWR-2510", "Arena Powered Cube · Oct 2025", "2025-10-30", "cube", 540, pack = true))
            if (alerts == null) alerts = true
            return
        }
        if (site.table1.events.data.Repo.userId == null) return
        runCatching { site.table1.events.library.RankingsStore.rankableSets() }.onSuccess { rankable = it }.onFailure { it.rethrowIfCancelled() }
        runCatching { T1App.supabase.postgrest.rpc("insights_alerts").data.let { json.decodeFromString<On>(it).on } }
            .onSuccess { alerts = it }.onFailure { it.rethrowIfCancelled() }
    }

    fun setAlerts(on: Boolean) {
        val was = alerts
        alerts = on
        Telemetry.capture("insights_alerts_changed", mapOf("on" to on))
        if (demo) return
        scope.launch {
            runCatching { T1App.supabase.postgrest.rpc("insights_alerts_set", buildJsonObject { put("p_on", on) }).data.let { json.decodeFromString<On>(it).on } }
                .onSuccess { alerts = it }
                .onFailure { it.rethrowIfCancelled(); alerts = was; error = "Couldn't change New in Insights: ${it.message}" }
        }
    }

    var section by mutableStateOf(runCatching { prefs.getString("section", "constructed") }.getOrNull() ?: "constructed"); private set
    var format by mutableStateOf(runCatching { prefs.getString("format", "modern") }.getOrNull() ?: "modern"); private set
    /** The tier the viewer picked; null = the pack's default (Big events unless they're thin). */
    var tierPicked by mutableStateOf(runCatching { prefs.getString("tier", null) }.getOrNull()); private set
    var days by mutableStateOf(runCatching { prefs.getInt("days", 30) }.getOrNull()?.takeIf { it in Insights.windows } ?: 30); private set
    var setCode by mutableStateOf(runCatching { prefs.getString("set", null) }.getOrNull()); private set
    /** Formats and sets kept out of the pickers on this device (Insights → Edit). */
    var hiddenFormats by mutableStateOf(runCatching { prefs.getStringSet("hiddenFormats", emptySet())?.toList() }.getOrNull() ?: emptyList()); private set
    var hiddenSets by mutableStateOf(runCatching { prefs.getStringSet("hiddenSets", emptySet())?.toList() }.getOrNull() ?: emptyList()); private set
    var event by mutableStateOf(runCatching { prefs.getString("event", "PremierDraft") }.getOrNull() ?: "PremierDraft"); private set
    var group by mutableStateOf(runCatching { prefs.getString("group", "all") }.getOrNull() ?: "all"); private set

    private fun save(k: String, v: Any?) {
        runCatching { prefs.edit().apply { when (v) { is Int -> putInt(k, v); null -> remove(k); else -> putString(k, v.toString()) } }.apply() }
        pushPicks()
    }

    /* The picks follow the account: read when Insights loads, written a moment after each change. */
    private var heldPicks: kotlinx.serialization.json.JsonObject? = null
    private var applying = false
    private var pushJob: kotlinx.coroutines.Job? = null

    val picks get() = InsightsPicks(section, format, tierPicked, days, setCode, event, group, hiddenFormats, hiddenSets)

    private fun pushPicks() {
        if (applying || demo || site.table1.events.data.Repo.userId == null) return
        pushJob?.cancel()
        pushJob = scope.launch {
            kotlinx.coroutines.delay(800)
            val next = InsightsPicks.write(picks, heldPicks)
            runCatching { site.table1.events.data.Repo.setInsightsPicks(next) }.onSuccess { heldPicks = next }
        }
    }

    /** The account's picks over this device's (the account wins; a device with none yet sends its own). */
    private suspend fun pullPicks() {
        val held = runCatching { site.table1.events.data.Repo.insightsPicks() }.getOrNull()
        heldPicks = held
        if (held == null || held.isEmpty()) { pushPicks(); return }
        val p = InsightsPicks.read(held)
        // Straight into the fields (and this device's copy), not through the pick functions: no "changed" telemetry
        // for a change nobody made here.
        applying = true
        try {
            p.section?.let { section = it; save("section", it) }
            p.format?.let { format = it; save("format", it) }
            p.tier?.let { tierPicked = it; save("tier", it) }
            p.days?.takeIf { it in Insights.windows }?.let { days = it; save("days", it) }
            p.set?.let { setCode = it; save("set", it) }
            p.event?.let { event = it; save("event", it) }
            p.group?.let { group = it; save("group", it) }
            p.hiddenFormats?.let { hiddenFormats = it; runCatching { prefs.edit().putStringSet("hiddenFormats", it.toSet()).apply() } }
            p.hiddenSets?.let { hiddenSets = it; runCatching { prefs.edit().putStringSet("hiddenSets", it.toSet()).apply() } }
        } finally { applying = false }
    }
    fun pickSection(v: String) { section = v; save("section", v); Telemetry.capture("insights_section_changed", mapOf("section" to v)) }
    fun pickFormat(v: String) { format = v; save("format", v); Telemetry.capture("insights_format_changed", mapOf("format" to v)) }
    fun pickTier(v: String) { tierPicked = v; save("tier", v); Telemetry.capture("insights_tier_changed", mapOf("tier" to v)) }
    fun pickDays(v: Int) { days = v; save("days", v); Telemetry.capture("insights_window_changed", mapOf("days" to v)) }
    val shownFormats: List<String> get() = Insights.visibleKeys(Insights.formats.map { it.first }, hiddenFormats)
    val shownSets: List<String> get() = Insights.visibleKeys(limitedSets.map { it.key }, hiddenSets)

    /** Shows or hides a format (or a set); a picked one that's hidden gives way to the first one still shown. */
    fun setHidden(format: Boolean, key: String, hide: Boolean) {
        if (format) {
            hiddenFormats = hiddenFormats.filter { it != key } + (if (hide) listOf(key) else emptyList())
            runCatching { prefs.edit().putStringSet("hiddenFormats", hiddenFormats.toSet()).apply() }
            pushPicks()
            if (this.format !in shownFormats) pickFormat(shownFormats.first())
        } else {
            hiddenSets = hiddenSets.filter { it != key } + (if (hide) listOf(key) else emptyList())
            runCatching { prefs.edit().putStringSet("hiddenSets", hiddenSets.toSet()).apply() }
            pushPicks()
            setCode?.let { if (it !in shownSets) shownSets.firstOrNull()?.let(::pickSet) }
        }
        Telemetry.capture("insights_picker_edited", mapOf("picker" to if (format) "formats" else "sets", "hidden" to (if (format) hiddenFormats else hiddenSets).size))
    }

    fun pickSet(v: String) { setCode = v; save("set", v); Telemetry.capture("insights_set_changed", mapOf("set" to v, "event" to event)) }
    fun pickEvent(v: String) { event = v; save("event", v); Telemetry.capture("insights_set_changed", mapOf("set" to (setCode ?: ""), "event" to v)) }
    fun pickGroup(v: String) { group = v; save("group", v) }

    val pack: ConstructedPack? get() = constructed[format]
    fun tier(p: ConstructedPack): String = tierPicked ?: p.default_tier
    val limitedSets: List<IndexEntry> get() = index.filter { it.kind == "limited" }
    fun events(p: LimitedPack) = Insights.eventOrder.filter { p.events.containsKey(it) }
    fun currentEvent(p: LimitedPack) = events(p).let { if (event in it) event else it.firstOrNull() }

    /** Packs being fetched, by "kind:key", so a pick and the background fill never fetch one twice. */
    private val fetching = HashMap<String, Deferred<Unit>>()
    /** Packs keep loading when the screen that asked goes away (leaving the tab mid-load used to stop the rest). */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val parallel = Semaphore(3)

    /**
     * The index, then the pack on screen (the picked format, or on Limited the picked set), then the rest, three at
     * a time. Packs were fetched one after another, constructed first, so a Limited set could wait behind the whole
     * metagame (seven Limited packs are 0.4–0.85 MB each).
     */
    suspend fun load(force: Boolean = false) {
        if (demo) return
        if (!force && System.currentTimeMillis() - loadedAt < 600_000 && index.isNotEmpty()) {
            fill()
            return
        }
        loading = true
        pullPicks()
        try {
            val raw = T1App.supabase.postgrest.rpc("insights_index").data
            index = withContext(Dispatchers.Default) { json.decodeFromString<List<IndexEntry>>(raw) }
            error = null
            loadedAt = System.currentTimeMillis()
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            error = "Insights couldn't load: ${e.message}"
        } finally {
            loading = false
        }
        fill()
    }

    /** Loads the packs on screen first and the rest behind them; returns once the one on screen is in. */
    private suspend fun fill() {
        val jobs = Insights.packOrder(index, section, format, setCode).filter { !has(it) }.map { start(it) }
        jobs.firstOrNull()?.await()
    }

    /** A pack the screen needs now (a picked set or format, a page opened from a link): fetched ahead of the rest. */
    suspend fun ensure(kind: String, key: String) {
        if (demo) return
        if (index.isEmpty()) load()
        val e = index.firstOrNull { it.kind == kind && it.key == key } ?: return
        if (!has(e)) start(e, first = true).await()
    }

    private fun has(e: IndexEntry) = if (e.kind == "constructed") constructed.containsKey(e.key) else limited.containsKey(e.key)

    private fun start(e: IndexEntry, first: Boolean = false): Deferred<Unit> = fetching.getOrPut("${e.kind}:${e.key}") {
        scope.async {
            try {
                if (first) fetch(e) else parallel.withPermit { fetch(e) }
            } finally { fetching.remove("${e.kind}:${e.key}") }
        }
    }

    /** A pack from the device when its version matches, else from the bucket; read and decoded off the main thread. */
    private suspend fun fetch(e: IndexEntry) {
        val text = withContext(Dispatchers.IO) {
            val dir = File(T1App.instance.cacheDir, "insights").apply { mkdirs() }
            val file = File(dir, "${e.kind}-${e.key}.json")
            val version = File(dir, "${e.kind}-${e.key}.version")
            if (file.exists() && runCatching { version.readText() }.getOrNull() == e.version) return@withContext file.readText()
            runCatching {
                val conn = URL("${e.url}?v=${e.version}").openConnection() as HttpURLConnection
                try {
                    conn.connectTimeout = 15_000; conn.readTimeout = 60_000
                    if (conn.responseCode != 200) throw java.io.IOException("pack ${e.key} ${conn.responseCode}")
                    conn.inputStream.use { it.readBytes() }.toString(Charsets.UTF_8)
                } finally { conn.disconnect() }
            }.onSuccess { file.writeText(it); version.writeText(e.version) }.getOrNull()
        } ?: run {
            // Without this the screen said "Loading…" for good; the next visit to Insights tries again.
            error = "Couldn't download the ${e.name.ifEmpty { e.key }} data. Check your connection."
            return
        }
        put(e.kind, e.key, text)
    }

    private suspend fun put(kind: String, key: String, text: String) {
        try {
            if (kind == "constructed") {
                val p = withContext(Dispatchers.Default) { json.decodeFromString<ConstructedPack>(text) }
                constructed = constructed + (key to p)
            } else {
                val p = withContext(Dispatchers.Default) { json.decodeFromString<LimitedPack>(text) }
                limited = limited + (key to p)
            }
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            error = "An Insights pack couldn't be read ($key)."
        }
    }

    suspend fun archetype(format: String, id: Int, tier: String, days: Int): ArchetypePage {
        if (demo) return json.decodeFromString(demoPages["arch:$format:$id"] ?: demoPages["arch:any"] ?: error("No demo page"))
        val raw = T1App.supabase.postgrest.rpc("meta_archetype", buildJsonObject {
            put("p_format", format); put("p_archetype", id); put("p_tier", tier); put("p_days", days)
        }).data
        return json.decodeFromString(raw)
    }

    suspend fun card(format: String, oracleId: String, tier: String): CardPage {
        if (demo) return json.decodeFromString(demoPages["card:$format:$oracleId"] ?: demoPages["card:any"] ?: error("No demo page"))
        val raw = T1App.supabase.postgrest.rpc("meta_card", buildJsonObject { put("p_format", format); put("p_oracle_id", oracleId); put("p_tier", tier) }).data
        return json.decodeFromString(raw)
    }

    /** Debug builds: the packs in assets/insights-demo (from real MTGO pages and a 17Lands slice, tools/insights/). */
    fun loadDemo(context: Context) {
        val files = context.assets.list("insights-demo") ?: return
        val entries = mutableListOf<IndexEntry>()
        for (f in files) {
            val text = context.assets.open("insights-demo/$f").use { it.readBytes().toString(Charsets.UTF_8) }
            val name = f.removeSuffix(".json")
            when {
                name.startsWith("constructed-") -> name.removePrefix("constructed-").let { constructed = constructed + (it to json.decodeFromString<ConstructedPack>(text)); entries += IndexEntry("constructed", it, it, "demo", "") }
                name.startsWith("limited-") -> name.removePrefix("limited-").let { limited = limited + (it to json.decodeFromString<LimitedPack>(text)); entries += IndexEntry("limited", it, it, "demo", "") }
                name == "pages" -> demoPages = json.decodeFromString<Map<String, kotlinx.serialization.json.JsonElement>>(text).mapValues { it.value.toString() }
            }
        }
        index = entries
        demo = true
    }
}
