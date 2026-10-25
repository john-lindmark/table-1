package site.table1.events.insights

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.util.Telemetry
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

    var section by mutableStateOf(runCatching { prefs.getString("section", "constructed") }.getOrNull() ?: "constructed"); private set
    var format by mutableStateOf(runCatching { prefs.getString("format", "modern") }.getOrNull() ?: "modern"); private set
    /** The tier the viewer picked; null = the pack's default (Big events unless they're thin). */
    var tierPicked by mutableStateOf(runCatching { prefs.getString("tier", null) }.getOrNull()); private set
    var days by mutableStateOf(runCatching { prefs.getInt("days", 30) }.getOrNull()?.takeIf { it in Insights.windows } ?: 30); private set
    var setCode by mutableStateOf(runCatching { prefs.getString("set", null) }.getOrNull()); private set
    var event by mutableStateOf(runCatching { prefs.getString("event", "PremierDraft") }.getOrNull() ?: "PremierDraft"); private set
    var group by mutableStateOf(runCatching { prefs.getString("group", "all") }.getOrNull() ?: "all"); private set

    private fun save(k: String, v: Any?) = runCatching {
        prefs.edit().apply { when (v) { is Int -> putInt(k, v); null -> remove(k); else -> putString(k, v.toString()) } }.apply()
    }
    fun pickSection(v: String) { section = v; save("section", v); Telemetry.capture("insights_section_changed", mapOf("section" to v)) }
    fun pickFormat(v: String) { format = v; save("format", v); Telemetry.capture("insights_format_changed", mapOf("format" to v)) }
    fun pickTier(v: String) { tierPicked = v; save("tier", v); Telemetry.capture("insights_tier_changed", mapOf("tier" to v)) }
    fun pickDays(v: Int) { days = v; save("days", v); Telemetry.capture("insights_window_changed", mapOf("days" to v)) }
    fun pickSet(v: String) { setCode = v; save("set", v); Telemetry.capture("insights_set_changed", mapOf("set" to v, "event" to event)) }
    fun pickEvent(v: String) { event = v; save("event", v); Telemetry.capture("insights_set_changed", mapOf("set" to (setCode ?: ""), "event" to v)) }
    fun pickGroup(v: String) { group = v; save("group", v) }

    val pack: ConstructedPack? get() = constructed[format]
    fun tier(p: ConstructedPack): String = tierPicked ?: p.default_tier
    val limitedSets: List<IndexEntry> get() = index.filter { it.kind == "limited" }
    fun events(p: LimitedPack) = Insights.eventOrder.filter { p.events.containsKey(it) }
    fun currentEvent(p: LimitedPack) = events(p).let { if (event in it) event else it.firstOrNull() }

    /** The index, then the pack on screen, then the rest. */
    suspend fun load(force: Boolean = false) {
        if (demo) return
        if (!force && System.currentTimeMillis() - loadedAt < 600_000 && index.isNotEmpty()) return
        loading = true
        try {
            val raw = T1App.supabase.postgrest.rpc("insights_index").data
            index = json.decodeFromString(raw)
            error = null
            loadedAt = System.currentTimeMillis()
        } catch (e: Exception) {
            error = "Insights couldn't load: ${e.message}"
        } finally {
            loading = false
        }
        index.firstOrNull { it.kind == "constructed" && it.key == format }?.let { fetch(it) }
        index.filter { !(it.kind == "constructed" && it.key == format) }.forEach { fetch(it) }
    }

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
        } ?: return
        put(e.kind, e.key, text)
    }

    private fun put(kind: String, key: String, text: String) {
        try {
            if (kind == "constructed") constructed = constructed + (key to json.decodeFromString<ConstructedPack>(text))
            else limited = limited + (key to json.decodeFromString<LimitedPack>(text))
        } catch (e: Exception) {
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
                name.startsWith("constructed-") -> name.removePrefix("constructed-").let { put("constructed", it, text); entries += IndexEntry("constructed", it, it, "demo", "") }
                name.startsWith("limited-") -> name.removePrefix("limited-").let { put("limited", it, text); entries += IndexEntry("limited", it, it, "demo", "") }
                name == "pages" -> demoPages = json.decodeFromString<Map<String, kotlinx.serialization.json.JsonElement>>(text).mapValues { it.value.toString() }
            }
        }
        index = entries
        demo = true
    }
}
