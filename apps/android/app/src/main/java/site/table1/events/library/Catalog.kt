package site.table1.events.library

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.net.ConnectivityManager
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import site.table1.events.T1App
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

// The offline card catalog (contract/catalog-2026-10-14.md): one gzipped TSV pack, downloaded only when its
// version changes, verified, and loaded into a local SQLite file. Search, the collection list and card detail
// all read from here; the server is only asked for prices and history.

@Serializable
data class CatalogInfo(val version: String, val format: Int, val url: String, val bytes: Long, val sha256: String)

data class CatalogOracle(
    val idx: Int, val oracleId: String, val name: String, val norm: String, val typeLine: String, val manaCost: String,
    val printings: Int,
    /** Legality code ([CatalogPack.LEGALITY_FORMATS]); empty in packs built before it existed. */
    val legal: String = "",
    /** Canadian Highlander points (0 = none). */
    val points: Int = 0,
    /** Mana value and colors (WUBRG letters, empty = colorless), for deck and cube stats. */
    val cmc: Double = 0.0,
    val colors: String = "",
) {
    /** Legality in a deck format: legal, restricted, banned, not_legal, or null when the format isn't checked. */
    fun legality(format: String): String? = CatalogPack.legality(legal, format)
}

data class CatalogPrinting(
    val cardId: String, val oracleIdx: Int,
    /** Position in the pack; within a card, lower is newer. */
    val ord: Int,
    val set: String, val cn: String, val lang: String, val rarity: String, val finishes: String, val releasedAt: String,
    val imageTs: String, val imageFaces: Int, val printedName: String,
    /** The card's original paper printing, the one adds use by default. */
    val original: Boolean = false,
) {
    val setLabel get() = "${set.uppercase()} #$cn"
    /** Finishes this printing comes in: non-foil, foil, etched (in that order). */
    val finishList: List<Finish> get() = finishes.mapNotNull { l -> CatalogPack.FINISH_NAME[l]?.let { Finish.of(it) } }.sortedBy { it.ordinal }
    fun imageUrl(size: String = "normal") = if (imageFaces == 0) null else CatalogPack.imageUrl(cardId, imageTs, size)
}

/** One installed pack. Read-only after it's built; Android's SQLiteDatabase serializes access itself. */
class CatalogDb(file: File, override val version: String) : ScanCatalog, ImportCatalog, ListCatalog {
    private val db = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY)

    fun close() = db.close()

    private inline fun <T> query(sql: String, args: Array<String>, map: (Cursor) -> T): List<T> = runCatching {
        db.rawQuery(sql, args).use { c -> buildList { while (c.moveToNext()) add(map(c)) } }
    }.getOrDefault(emptyList())

    /** Card name search, ranked like the web client. */
    fun search(query: String, limit: Int = 40): List<CatalogOracle> {
        val q = CardName.norm(query)
        if (q.length < 2) return emptyList()
        val rows = query("SELECT $ORACLE_COLS FROM oracles WHERE instr(name_norm, ?) > 0", arrayOf(q), ::oracle)
        val byIdx = rows.associateBy { it.idx }
        return CatalogPack.rank(rows.map { CatalogPack.SearchCandidate(it.idx, it.norm, it.typeLine, it.printings) }, q, limit)
            .mapNotNull { byIdx[it] }
    }

    override fun scanNames(): List<ScanName> =
        query("SELECT idx, name, name_norm, type_line, pcount FROM oracles", emptyArray()) {
            ScanName(it.getInt(0), it.getString(1), it.getString(2), it.getString(3) ?: "", it.getInt(4))
        }

    override fun foreignNames(): List<Pair<Int, String>> =
        query("SELECT DISTINCT oracle_idx, name_norm FROM names", emptyArray()) { it.getInt(0) to it.getString(1) }

    override fun setCodes(): Set<String> = query("SELECT DISTINCT set_code FROM printings", emptyArray()) { it.getString(0) }.toSet()

    override fun importNames(): List<ImportName> =
        query("SELECT idx, name_norm, face_names, type_line, pcount FROM oracles", emptyArray()) {
            ImportName(it.getInt(0), it.getString(1), it.getString(2) ?: "", (it.getString(3) ?: "").startsWith("Token"), it.getInt(4))
        }

    override fun printings(set: String): List<CatalogPrinting> =
        query("SELECT $PRINTING_COLS FROM printings WHERE set_code = ?", arrayOf(set), ::printing)

    override fun printings(set: String, cn: String): List<CatalogPrinting> =
        query("SELECT $PRINTING_COLS FROM printings WHERE set_code = ? AND cn = ? ORDER BY lang = 'en' DESC", arrayOf(set, cn), ::printing)

    fun oracle(id: String): CatalogOracle? = query("SELECT $ORACLE_COLS FROM oracles WHERE oracle_id = ?", arrayOf(id), ::oracle).firstOrNull()

    /** Every printing of a card: the original paper printing (the default for adds) first, then newest first. */
    override fun printings(oracleIdx: Int): List<CatalogPrinting> =
        query("SELECT $PRINTING_COLS FROM printings WHERE oracle_idx = ? ORDER BY original DESC, ord", arrayOf(oracleIdx.toString()), ::printing)

    override fun printings(ids: Collection<String>): Map<String, CatalogPrinting> =
        ids.chunked(500).flatMap { chunk ->
            query("SELECT $PRINTING_COLS FROM printings WHERE card_id IN (${chunk.joinToString(",") { "?" }})", chunk.toTypedArray(), ::printing)
        }.associateBy { it.cardId }

    /**
     * One printing per card, shown as its picture and used when it's added: its original paper printing (flagged
     * in the pack), else the newest English printing with an image, else the newest.
     */
    override fun covers(oracleIdxs: Collection<Int>): Map<Int, CatalogPrinting> {
        val out = HashMap<Int, CatalogPrinting>()
        oracleIdxs.chunked(500).forEach { chunk ->
            query("SELECT $PRINTING_COLS FROM printings WHERE oracle_idx IN (${chunk.joinToString(",") { "?" }}) " +
                "ORDER BY oracle_idx, original DESC, (lang = 'en' AND image_faces > 0) DESC, ord",
                chunk.map { it.toString() }.toTypedArray(), ::printing).forEach { p -> out.putIfAbsent(p.oracleIdx, p) }
        }
        return out
    }

    /**
     * Default printings for card names as decklists print them: exact names, or the front face of a split or
     * double-faced card ("Delver of Secrets" finds "Delver of Secrets // Insectile Aberration"). Names that
     * match no card are left out.
     */
    override fun printingsByName(names: Collection<String>): Map<String, CatalogPrinting> {
        val idx = HashMap<String, Int>()
        for (name in names.toSet()) {
            val exact = query("SELECT idx FROM oracles WHERE name_norm = ? LIMIT 1", arrayOf(CardName.norm(name))) { it.getInt(0) }.firstOrNull()
            val found = exact ?: query("SELECT idx FROM oracles WHERE name LIKE ? ORDER BY pcount DESC LIMIT 1",
                arrayOf(name.replace("%", "") + " // %")) { it.getInt(0) }.firstOrNull()
            if (found != null) idx[name] = found
        }
        val covers = covers(idx.values.toSet())
        return idx.mapNotNull { (n, i) -> covers[i]?.let { n to it } }.toMap()
    }

    /** Printings by set code and collector number ("set|cn"), English first when a set has several languages. */
    override fun printingsBySetCn(pairs: Collection<Pair<String, String>>): Map<String, CatalogPrinting> {
        val out = HashMap<String, CatalogPrinting>()
        for ((set, cn) in pairs) {
            val k = "$set|$cn"
            if (k in out) continue
            query("SELECT $PRINTING_COLS FROM printings WHERE set_code = ? AND cn = ? ORDER BY lang = 'en' DESC LIMIT 1",
                arrayOf(set.lowercase(), cn), ::printing).firstOrNull()?.let { out[k] = it }
        }
        return out
    }

    override fun oracles(idxs: Collection<Int>): Map<Int, CatalogOracle> =
        idxs.chunked(500).flatMap { chunk ->
            query("SELECT $ORACLE_COLS FROM oracles WHERE idx IN (${chunk.joinToString(",") { "?" }})",
                chunk.map { it.toString() }.toTypedArray(), ::oracle)
        }.associateBy { it.idx }

    companion object {
        private const val ORACLE_COLS = "idx, oracle_id, name, name_norm, type_line, mana_cost, pcount, legal, points, cmc, colors"
        private const val PRINTING_COLS =
            "card_id, oracle_idx, ord, set_code, cn, lang, rarity, finishes, released_at, image_ts, image_faces, printed_name, original"

        private fun oracle(c: Cursor) = CatalogOracle(c.getInt(0), c.getString(1), c.getString(2), c.getString(3),
            c.getString(4) ?: "", c.getString(5) ?: "", c.getInt(6), c.getString(7) ?: "", c.getInt(8), c.getDouble(9), c.getString(10) ?: "")

        private fun printing(c: Cursor) = CatalogPrinting(c.getString(0), c.getInt(1), c.getInt(2), c.getString(3) ?: "",
            c.getString(4) ?: "", c.getString(5) ?: "", c.getString(6) ?: "", c.getString(7) ?: "", c.getString(8) ?: "",
            c.getString(9) ?: "", c.getInt(10), c.getString(11) ?: "", c.getInt(12) != 0)

        /** Builds a SQLite file from a gunzipped pack in one transaction; indexes are created after the inserts. */
        fun build(pack: String, file: File): PackHeader {
            file.delete()
            File(file.path + "-journal").delete()
            val db = SQLiteDatabase.openOrCreateDatabase(file, null)
            try {
                db.disableWriteAheadLogging() // one plain file, so it can be renamed into place
                db.execSQL("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
                db.execSQL("""CREATE TABLE oracles (idx INTEGER PRIMARY KEY, oracle_id TEXT NOT NULL, name TEXT NOT NULL,
                    name_norm TEXT NOT NULL, type_line TEXT, mana_cost TEXT, cmc REAL, colors TEXT, face_names TEXT,
                    pcount INTEGER NOT NULL DEFAULT 0, legal TEXT NOT NULL DEFAULT '', points INTEGER NOT NULL DEFAULT 0)""")
                db.execSQL("""CREATE TABLE printings (card_id TEXT PRIMARY KEY, oracle_idx INTEGER NOT NULL, ord INTEGER NOT NULL,
                    set_code TEXT, cn TEXT, lang TEXT, rarity TEXT, finishes TEXT, released_at TEXT, image_ts TEXT,
                    image_faces INTEGER, printed_name TEXT, original INTEGER NOT NULL DEFAULT 0)""")
                db.execSQL("CREATE TABLE names (oracle_idx INTEGER NOT NULL, lang TEXT NOT NULL, name TEXT NOT NULL, name_norm TEXT NOT NULL)")
                db.beginTransaction()
                try {
                    val insO = db.compileStatement(
                        "INSERT INTO oracles (idx, oracle_id, name, name_norm, type_line, mana_cost, cmc, colors, face_names, legal, points) VALUES (?,?,?,?,?,?,?,?,?,?,?)")
                    val insP = db.compileStatement("INSERT OR REPLACE INTO printings VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)")
                    val insN = db.compileStatement("INSERT INTO names VALUES (?,?,?,?)")
                    var ord = 0L
                    val header = CatalogPack.parse(pack, oracle = { o ->
                        insO.clearBindings()
                        insO.bindLong(1, o.idx.toLong()); insO.bindString(2, o.oracleId); insO.bindString(3, o.name)
                        insO.bindString(4, o.nameNorm); insO.bindString(5, o.typeLine); insO.bindString(6, o.manaCost)
                        insO.bindDouble(7, o.cmc); insO.bindString(8, o.colors); insO.bindString(9, o.faceNames)
                        insO.bindString(10, o.legal)
                        insO.bindLong(11, o.points.toLong())
                        insO.executeInsert()
                    }, printing = { p ->
                        insP.clearBindings()
                        insP.bindString(1, p.cardId); insP.bindLong(2, p.oracleIdx.toLong()); insP.bindLong(3, ord++)
                        insP.bindString(4, p.set); insP.bindString(5, p.cn); insP.bindString(6, p.lang); insP.bindString(7, p.rarity)
                        insP.bindString(8, p.finishes); insP.bindString(9, p.releasedAt); insP.bindString(10, p.imageTs)
                        insP.bindLong(11, p.imageFaces.toLong()); insP.bindString(12, p.printedName)
                        insP.bindLong(13, if (p.original) 1 else 0)
                        insP.executeInsert()
                    }, name = { n ->
                        // Normalized here, once per pack, so the scanner's name index loads without normalizing 160k names.
                        val norm = CardName.norm(n.name)
                        if (norm.isNotEmpty()) {
                            insN.clearBindings()
                            insN.bindLong(1, n.oracleIdx.toLong()); insN.bindString(2, n.lang); insN.bindString(3, n.name)
                            insN.bindString(4, norm)
                            insN.executeInsert()
                        }
                    })
                    db.execSQL("CREATE INDEX printings_oracle ON printings (oracle_idx, ord)")
                    db.execSQL("CREATE INDEX printings_set_cn ON printings (set_code, cn, lang)")
                    db.execSQL("CREATE INDEX oracles_norm ON oracles (name_norm)")
                    db.execSQL("CREATE INDEX oracles_id ON oracles (oracle_id)")
                    db.execSQL("UPDATE oracles SET pcount = (SELECT count(*) FROM printings WHERE oracle_idx = oracles.idx)")
                    db.execSQL("INSERT INTO meta VALUES ('version', ?)", arrayOf(header.version))
                    db.setTransactionSuccessful()
                    return header
                } finally {
                    db.endTransaction()
                }
            } finally {
                db.close()
            }
        }
    }
}

data class CatalogState(
    /** idle | loading | ready | failed */
    val phase: String = "idle",
    val error: String? = null,
    /** Bumped whenever a pack is opened or replaced; screens re-query on it. */
    val generation: Int = 0,
)

/**
 * Owns the installed pack: opens it at launch, checks `catalog_info` at most once a day, and swaps in a new
 * version atomically (the old one stays in use until the new one is built).
 */
object CatalogStore {
    /** Bumped when the local SQLite schema changes; a file built by an older schema is rebuilt from a fresh pack. */
    private const val SCHEMA = "s5"   // s5: name_norm keeps Han, kana and Hangul

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow(CatalogState())
    val state: StateFlow<CatalogState> = _state.asStateFlow()
    @Volatile var db: CatalogDb? = null
        private set
    private var running: Job? = null
    /** With a pack installed, a failed update (offline, metered) waits an hour before the next try. */
    private var lastAttempt = 0L

    private val ctx get() = T1App.instance
    private val prefs get() = ctx.getSharedPreferences("catalog", Context.MODE_PRIVATE)
    private val dir get() = File(ctx.filesDir, "catalog").apply { mkdirs() }

    /**
     * [userInitiated]: the Library is on screen. A first pack then downloads on any network; otherwise (at
     * launch, or when a pack is already installed) only on an unmetered network.
     */
    fun load(userInitiated: Boolean) {
        if (db == null) openInstalled()
        if (running?.isActive == true) return
        val checked = prefs.getLong("checkedAt", 0)
        if (db != null && System.currentTimeMillis() - checked < 86_400_000) return
        if (db != null && System.currentTimeMillis() - lastAttempt < 3_600_000) return
        lastAttempt = System.currentTimeMillis()
        running = scope.launch { refresh(anyNetwork = db == null && userInitiated) }
    }

    private fun openInstalled() {
        val version = prefs.getString("version", null) ?: return
        val file = File(dir, "catalog-$version.$SCHEMA.sqlite")
        if (!file.exists()) return
        db = runCatching { CatalogDb(file, version) }.getOrNull() ?: return
        _state.update { it.copy(phase = "ready", error = null, generation = it.generation + 1) }
    }

    private fun fail(message: String) = _state.update { it.copy(phase = "failed", error = message) }

    private suspend fun refresh(anyNetwork: Boolean) {
        val hadPack = db != null
        if (!hadPack) _state.update { it.copy(phase = "loading", error = null) }
        try {
            val raw = T1App.supabase.postgrest.rpc("catalog_info").decodeAs<kotlinx.serialization.json.JsonElement>()
            if (raw == JsonNull || raw !is JsonObject) {
                if (!hadPack) fail("Card data isn't available yet")
                return
            }
            val info = T1App.json.decodeFromJsonElement<CatalogInfo>(raw)
            if (info.version == db?.version) {
                prefs.edit().putLong("checkedAt", System.currentTimeMillis()).apply()
                return
            }
            if (info.format != 1) {
                if (!hadPack) fail("Update Table 1 to load the latest card data")
                return
            }
            val metered = (ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).isActiveNetworkMetered
            if (metered && !anyNetwork) {
                if (!hadPack) _state.update { it.copy(phase = "idle") } // waits for the Library or Wi-Fi
                return
            }
            val file = File(dir, "catalog-${info.version}.$SCHEMA.sqlite")
            withContext(Dispatchers.IO) { install(info, file) }
            val opened = CatalogDb(file, info.version)
            val old = db
            db = opened
            prefs.edit().putString("version", info.version).putLong("checkedAt", System.currentTimeMillis()).apply()
            _state.update { it.copy(phase = "ready", error = null, generation = it.generation + 1) }
            old?.close()
            dir.listFiles()?.filter { it.name != file.name && it.name.startsWith("catalog-") }?.forEach { it.delete() }
        } catch (e: Exception) {
            // With a pack installed, keep using it quietly and try again next launch.
            if (!hadPack) fail(e.message ?: "Couldn't load card data")
        }
    }

    private fun install(info: CatalogInfo, file: File) {
        val conn = URL(info.url).openConnection() as HttpURLConnection
        val bytes = try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 60_000
            if (conn.responseCode != 200) throw CatalogFormatException("Card data ${conn.responseCode}")
            conn.inputStream.use { it.readBytes() }
        } finally {
            conn.disconnect()
        }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        if (digest != info.sha256.lowercase()) throw CatalogFormatException("Card data didn't download completely")
        val text = String(CatalogPack.gunzip(bytes), Charsets.UTF_8)
        val building = File(dir, "building.sqlite")
        CatalogDb.build(text, building)
        file.delete()
        if (!building.renameTo(file)) throw CatalogFormatException("Couldn't save card data")
    }
}
