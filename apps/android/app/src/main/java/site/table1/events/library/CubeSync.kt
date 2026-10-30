package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled

// Sync a cube with Cube Cobra (contract/cube-sync-2026-10-30.md): what's in, out and in a new printing or finish between
// the cube and Cube Cobra's answer, and the entries to save. Shared cases: testdata/cube-sync/cases.json.

object CubeSync {
    data class Line(val board: String, val card: String, val finish: String, val lang: String, val qty: Int)
    data class Changed(val board: String, val fromCard: String, val fromFinish: String, val fromLang: String,
                       val toCard: String, val toFinish: String, val toLang: String, val qty: Int)
    /** A printing's card (oracle) and language, from the catalog. */
    data class Printing(val oracle: String, val lang: String)

    data class Result(val into: List<Line>, val out: List<Line>, val changed: List<Changed>, val same: Int, val entries: List<ListEntry>) {
        val inCount get() = into.sumOf { it.qty }
        val outCount get() = out.sumOf { it.qty }
        val changedCount get() = changed.sumOf { it.qty }
        val isEmpty get() = into.isEmpty() && out.isEmpty() && changed.isEmpty()

        /** "3 in · 2 out · 5 new printings", or "Up to date". */
        val summary: String get() = listOfNotNull(
            if (inCount > 0) "$inCount in" else null,
            if (outCount > 0) "$outCount out" else null,
            if (changedCount > 0) "$changedCount new printing${if (changedCount == 1) "" else "s"}" else null,
        ).joinToString(" · ").ifEmpty { "Up to date" }
    }

    private fun cmp(a: List<String>, b: List<String>): Int {
        for (i in 0 until minOf(a.size, b.size)) { val c = a[i].compareTo(b[i]); if (c != 0) return c }
        return a.size - b.size
    }
    private val byParts = Comparator<List<String>> { a, b -> cmp(a, b) }
    /** English first, then by code. */
    private fun langKey(l: String) = if (l == "en") "0" else "1$l"

    fun diff(current: List<ListEntry>, incoming: List<ListEntry>, printings: Map<String, Printing>): Result {
        val plang = { c: String -> printings[c]?.lang ?: "en" }
        val oracle = { c: String -> printings[c]?.oracle ?: c }
        val cur = HashMap<List<String>, Int>() // board, card, finish, lang
        for (e in current) cur.merge(listOf(e.board, e.cardId, e.finish, e.lang), e.qty, Int::plus)
        val inc = HashMap<List<String>, Int>() // board, card, finish
        for (e in incoming) inc.merge(listOf(e.board, e.cardId, e.finish), e.qty, Int::plus)
        val final = HashMap<List<String>, Int>()
        val changed = HashMap<List<String>, Int>()
        var same = 0
        val incKeys = inc.keys.sortedWith(byParts)

        // 1. Same printing and finish.
        for (k in incKeys) {
            for (m in cur.keys.filter { it.subList(0, 3) == k }.sortedBy { langKey(it[3]) }) {
                val n = minOf(inc[k]!!, cur[m]!!)
                if (n <= 0) continue
                cur[m] = cur[m]!! - n; inc[k] = inc[k]!! - n
                final.merge(m, n, Int::plus)
                same += n
            }
        }

        // 2. Same printing, other finish. 3. Same card, other printing.
        fun pair(match: (List<String>, String) -> Boolean) {
            for (k in incKeys) {
                val (b, c, f) = k
                val order = cur.keys.sortedWith { x, y -> cmp(x.subList(0, 3) + langKey(x[3]), y.subList(0, 3) + langKey(y[3])) }
                for (m in order) {
                    if (inc[k]!! <= 0) break
                    if (cur[m]!! <= 0 || m[0] != b || !match(m, c)) continue
                    val n = minOf(inc[k]!!, cur[m]!!)
                    cur[m] = cur[m]!! - n; inc[k] = inc[k]!! - n
                    val toLang = changedLang(m[1], m[3], c, plang)
                    final.merge(listOf(b, c, f, toLang), n, Int::plus)
                    changed.merge(listOf(b, m[1], m[2], m[3], c, f, toLang), n, Int::plus)
                }
            }
        }
        pair { m, c -> m[1] == c }
        pair { m, c -> oracle(m[1]) == oracle(c) }

        val into = HashMap<List<String>, Int>()
        for ((k, n) in inc) {
            if (n <= 0) continue
            val key = listOf(k[0], k[1], k[2], plang(k[1]))
            into.merge(key, n, Int::plus)
            final.merge(key, n, Int::plus)
        }
        fun sorted(m: Map<List<String>, Int>) = m.filter { it.value > 0 }.toSortedMap(byParts).entries
        val line = { k: List<String>, n: Int -> Line(k[0], k[1], k[2], k[3], n) }
        return Result(
            into = sorted(into).map { line(it.key, it.value) },
            out = sorted(cur).map { line(it.key, it.value) },
            changed = sorted(changed).map { (k, n) -> Changed(k[0], k[1], k[2], k[3], k[4], k[5], k[6], n) },
            same = same,
            entries = sorted(final).map { (k, n) -> ListEntry(k[1], k[0], n, k[2], k[3]) },
        )
    }

    /** The new printing's own language when it isn't English; else the old line's when it wasn't its printing's own; else
     *  English. */
    fun changedLang(fromCard: String, fromLang: String, toCard: String, plang: (String) -> String): String {
        val to = plang(toCard)
        if (to != "en") return to
        if (fromLang != plang(fromCard)) return fromLang
        return "en"
    }

    /** The Cube Cobra id in a link ("cubecobra.com/cube/list/<id>", "/c/<id>"), for the row's detail. */
    fun cubeId(link: String?): String? {
        if (link.isNullOrBlank()) return null
        val m = Regex("^(?:https?://)?(?:[a-z0-9-]+\\.)*cubecobra\\.com(/[^?#]*)?", RegexOption.IGNORE_CASE).find(link.trim()) ?: return null
        val p = (m.groupValues[1]).split("/").filter { it.isNotEmpty() }
        return when {
            p.firstOrNull() == "c" && p.size > 1 -> p[1]
            p.firstOrNull() == "cube" && p.size >= 3 -> p[2]
            p.firstOrNull() == "cube" && p.size == 2 -> p[1]
            else -> null
        }
    }
}

private data class Checked(val source: String, val name: String, val cards: Int, val seq: Long?, val result: CubeSync.Result,
                           val missing: List<String>, val printings: Map<String, CatalogPrinting>, val names: Map<String, CatalogOracle>)

/** Sync with Cube Cobra: reads the cube on Cube Cobra again, shows what's in, out and in a new printing or finish, and on
 *  Accept saves it as one new version. Same flow as iOS and the web. */
@Composable
fun CubeSyncScreen(listId: String, onBack: () -> Unit, onCard: (String) -> Unit) {
    val state by ListsStore.state.collectAsState()
    val list = state.lists.firstOrNull { it.id == listId }
    val scope = rememberCoroutineScope()
    var link by remember { mutableStateOf("") }
    var asking by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var conflict by remember { mutableStateOf(false) }
    var checked by remember { mutableStateOf<Checked?>(null) }
    var started by remember { mutableStateOf(false) }

    fun check(url0: String) {
        val l = ListsStore.list(listId) ?: return
        val url = url0.trim().let { if (it.startsWith("http", ignoreCase = true)) it else "https://$it" }
        if (CubeSync.cubeId(url) == null) { error = "That isn't a Cube Cobra cube link."; return }
        busy = true; error = null; conflict = false
        scope.launch {
            val r = readImport(url, "")
            val db = CatalogStore.db
            when {
                r.error != null -> { error = r.error; asking = true; Telemetry.capture("cube_sync_failed", mapOf("reason" to "read")) }
                db == null -> error = "Card data is still loading. Try again in a moment."
                else -> {
                    val out = withContext(Dispatchers.Default) {
                        val resolved = resolveImport(r.entries, ListKind.Cube, db)
                        val ids = (l.entries.map { it.cardId } + resolved.entries.map { it.cardId }).toSet()
                        val printings = db.printings(ids)
                        val result = CubeSync.diff(l.entries, resolved.entries, printings.mapValues { CubeSync.Printing("${it.value.oracleIdx}", it.value.lang) })
                        val oracles = db.oracles(printings.values.map { it.oracleIdx }.toSet())
                        Checked(r.sourceUrl ?: url, r.name ?: "", r.entries.filter { it.board == "main" }.sumOf { it.qty }, l.seq, result,
                            resolved.missing, printings, printings.mapNotNull { (id, p) -> oracles[p.oracleIdx]?.let { id to it } }.toMap())
                    }
                    checked = out
                    asking = false
                    val res = out.result
                    Telemetry.capture("cube_sync_checked", mapOf("in" to res.inCount, "out" to res.outCount, "changed" to res.changedCount,
                        "same" to res.same, "missing" to out.missing.size, "known_link" to (l.sourceUrl != null)))
                }
            }
            busy = false
        }
    }

    fun accept(c: Checked) {
        busy = true
        scope.launch {
            try {
                ListsStore.syncList(listId, c.seq, c.result.entries, c.source)
                Telemetry.capture("cube_sync_accepted", mapOf("in" to c.result.inCount, "out" to c.result.outCount, "changed" to c.result.changedCount))
                onBack()
            } catch (e: Exception) {
                e.rethrowIfCancelled()
                if (ListsStore.isSyncConflict(e)) {
                    conflict = true
                    error = "This cube changed since you checked. Check again."
                    Telemetry.capture("cube_sync_failed", mapOf("reason" to "conflict"))
                } else {
                    error = e.message ?: "The cube couldn't be saved."
                    Telemetry.capture("cube_sync_failed", mapOf("reason" to "save"))
                }
            }
            busy = false
        }
    }

    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    val catalogReady = CatalogStore.db != null
    LaunchedEffect(catalogReady, list?.id) {
        if (started || !catalogReady || list == null) return@LaunchedEffect
        started = true
        val src = list.sourceUrl
        if (src != null) { link = src; check(src) } else asking = true
    }

    T1Screen {
        Bar("Sync with Cube Cobra", subtitle = list?.name, onBack = onBack)
        error?.let { Notice(it, error = true) }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            val c = checked
            when {
                list == null -> item { ListRow("This cube isn't here any more") }
                !catalogReady -> item { ListRow("Loading card data…") }
                asking -> {
                    item { Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) { T1TextField(link, { link = it }, label = "Cube Cobra link") } }
                    item { Notice("Paste the cube's link from Cube Cobra. Table 1 remembers it for next time.") }
                    item { BigAction(if (busy) "Reading Cube Cobra…" else "Check", enabled = !busy && link.isNotBlank(), busy = busy) { check(link) } }
                }
                c == null -> if (started) item { ListRow("Reading Cube Cobra…", CubeSync.cubeId(link)?.let { "cubecobra.com · $it" }) }
                else -> {
                    val r = c.result
                    item { ListRow(r.summary, "Cube Cobra · ${c.name} · ${c.cards} cards") }
                    if (c.missing.isNotEmpty()) item {
                        Notice("Not in the card data, left out: ${c.missing.take(12).joinToString(", ")}${if (c.missing.size > 12) " and ${c.missing.size - 12} more" else ""}", error = true)
                    }
                    if (conflict) item { BigAction(if (busy) "Reading Cube Cobra…" else "Check again", enabled = !busy, busy = busy) { check(c.source) } }
                    else if (!r.isEmpty) item { BigAction(if (busy) "Saving…" else "Accept changes", enabled = !busy, busy = busy) { accept(c) } }
                    item { ListRow(if (r.isEmpty) "Back to the cube" else "Keep as it is", onClick = onBack) }
                    item {
                        ListRow("Change link", CubeSync.cubeId(c.source)?.let { "cubecobra.com · $it" },
                            onClick = { asking = true; checked = null; error = null; conflict = false })
                    }
                    val label = { id: String -> c.printings[id]?.setLabel ?: "?" }
                    val cap = { s: String -> s.replaceFirstChar { it.uppercase() } }
                    if (r.into.isNotEmpty()) {
                        item(key = "s-in") { Section("In · ${r.inCount}") }
                        items(r.into, key = { "in-${it.board}-${it.card}-${it.finish}-${it.lang}" }) { l ->
                            SyncRow(c, l.card, onCard, listOf(label(l.card), if (l.finish == "nonfoil") null else cap(l.finish), if (l.lang == "en") null else l.lang.uppercase(),
                                if (l.board == "maybe") "Considering" else null), "+${l.qty}", false)
                        }
                    }
                    if (r.out.isNotEmpty()) {
                        item(key = "s-out") { Section("Out · ${r.outCount}") }
                        items(r.out, key = { "out-${it.board}-${it.card}-${it.finish}-${it.lang}" }) { l ->
                            SyncRow(c, l.card, onCard, listOf(label(l.card), if (l.finish == "nonfoil") null else cap(l.finish), if (l.lang == "en") null else l.lang.uppercase(),
                                if (l.board == "maybe") "Considering" else null), "−${l.qty}", true)
                        }
                    }
                    if (r.changed.isNotEmpty()) {
                        item(key = "s-ch") { Section("New printing or finish · ${r.changedCount}") }
                        items(r.changed, key = { "ch-${it.board}-${it.fromCard}-${it.fromFinish}-${it.fromLang}-${it.toCard}-${it.toFinish}" }) { ch ->
                            val finish = if (ch.fromFinish == "nonfoil" && ch.toFinish == "nonfoil") null
                                else (if (ch.fromFinish == ch.toFinish) "" else "${cap(ch.fromFinish)} → ") + cap(ch.toFinish)
                            val sets = if (ch.fromCard == ch.toCard) label(ch.toCard) else "${label(ch.fromCard)} → ${label(ch.toCard)}"
                            SyncRow(c, ch.toCard, onCard, listOf(sets, finish, if (ch.toLang == "en") null else ch.toLang.uppercase(),
                                if (ch.board == "maybe") "Considering" else null), "${ch.qty}", false)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SyncRow(c: Checked, card: String, onCard: (String) -> Unit, detail: List<String?>, value: String, warn: Boolean) {
    CardRow(c.printings[card], c.names[card]?.name ?: "…", detail.filterNotNull().joinToString(" · "),
        onClick = { c.names[card]?.oracleId?.let(onCard) }) {
        Text(value, color = if (warn) T1.error else T1.text, fontFamily = T1.mono, fontSize = 17.sp)
    }
}
