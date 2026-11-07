package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.components.T1FullScreenDialog
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* The search row every Add cards screen shares (contract/library-polish-2026-10-19.md): the box (a name, or Scryfall
   syntax), Adv (the form that writes the syntax) and Scan (the camera, when the screen can take scanned cards). */

/** Runs the box's search after typing settles: the ranked name search, the local advanced search, or Scryfall. Null
 *  while the box is empty. */
@Composable
fun rememberCardSearch(query: String): CardSearchEngine.Result? {
    val cat by CatalogStore.state.collectAsState()
    var result by remember { mutableStateOf<CardSearchEngine.Result?>(null) }
    LaunchedEffect(query, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        if (query.isBlank()) { result = null; return@LaunchedEffect }
        delay(CardSearchEngine.debounce(query)) // let typing settle
        val q = query
        result = withContext(Dispatchers.IO) { CardSearchEngine.run(q, db) }
    }
    return result
}

@Composable
fun CardSearchBar(query: String, onChange: (String) -> Unit, placeholder: String = "Name, or Scryfall syntax", label: String? = null,
                  onScan: (() -> Unit)? = null, onSubmit: (() -> Unit)? = null) {
    var advanced by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        Box(Modifier.weight(1f).background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
            T1TextField(query, onChange, label = label, placeholder = placeholder, onSubmit = onSubmit)
        }
        Side("Adv") { advanced = true }
        if (onScan != null) Side("Scan", onScan)
    }
    if (advanced) AdvancedSearchPanel(query, onClose = { advanced = false }) { onChange(it); advanced = false }
}

@Composable
private fun Side(text: String, onClick: () -> Unit) {
    Box(Modifier.fillMaxHeight().background(T1.surface).clickable(onClick = onClick).padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
        Label(text, color = T1.text)
    }
}

/** A line under the search box saying what an advanced search found, and where. */
@Composable
fun CardSearchStatus(query: String, result: CardSearchEngine.Result?) {
    val r = result ?: return
    if (!CardQuery.hasSyntax(query)) return
    if (r.error != null) { Notice(r.error, error = true); return }
    val shown = if (r.hits.size < r.total) "${r.hits.size} of ${count(r.total)}" else count(r.total)
    Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 8.dp)) {
        Label("$shown card${if (r.total == 1) "" else "s"}${if (r.remote) " · from Scryfall" else ""}")
    }
}

private val FORMATS = listOf("" to "Any", "standard" to "Standard", "pioneer" to "Pioneer", "modern" to "Modern", "legacy" to "Legacy",
    "vintage" to "Vintage", "pauper" to "Pauper", "commander" to "Commander", "premodern" to "Premodern")
private val MV_OPS = listOf("=" to "=", "<" to "<", "<=" to "≤", ">" to ">", ">=" to "≥")
private val RARITY_LABEL = mapOf('c' to "Common", 'u' to "Uncommon", 'r' to "Rare", 'm' to "Mythic")

/** Scryfall's advanced search, kept to what players filter by. The fields are written as syntax into the search box,
 *  so the search can be edited there afterwards. */
@Composable
fun AdvancedSearchPanel(start: String, onClose: () -> Unit, onApply: (String) -> Unit) {
    var f by remember { mutableStateOf(if (CardQuery.hasSyntax(start)) AdvancedSearchFields() else AdvancedSearchFields(name = start)) }
    LaunchedEffect(Unit) { Telemetry.screen("advanced_search") }
    T1FullScreenDialog(onDismissRequest = onClose) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Advanced search", subtitle = "Scryfall syntax", onBack = onClose) { BarAction("Clear") { f = AdvancedSearchFields() } }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Field("Card name", f.name) { f = f.copy(name = it) }
                    Field("Text · needs a connection", f.text) { f = f.copy(text = it) }
                    Field("Type line · e.g. legendary creature", f.type) { f = f.copy(type = it) }
                    Section("Colors")
                    Toggles(listOf('W', 'U', 'B', 'R', 'G', 'C'), f.colors, { it.toString() }) { f = f.copy(colors = it) }
                    if (f.colors.isNotEmpty() && 'C' !in f.colors) {
                        val modes = AdvancedSearchFields.ColorMode.entries
                        T1Segmented(modes.map { it.label }, modes.indexOf(f.colorMode)) { f = f.copy(colorMode = modes[it]) }
                    }
                    Section("Mana value")
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                        Box(Modifier.weight(1f)) {
                            T1Segmented(MV_OPS.map { it.second }, MV_OPS.indexOfFirst { it.first == f.mvOp }) { f = f.copy(mvOp = MV_OPS[it].first) }
                        }
                        Box(Modifier.width(72.dp).fillMaxHeight().background(T1.surface).padding(horizontal = 4.dp, vertical = 2.dp),
                            contentAlignment = Alignment.Center) {
                            T1TextField(f.mv, { f = f.copy(mv = it) }, placeholder = "3", keyboardType = KeyboardType.Decimal)
                        }
                    }
                    Section("Rarity")
                    Toggles(listOf('c', 'u', 'r', 'm'), f.rarities, { RARITY_LABEL[it] ?: it.toString() }) { f = f.copy(rarities = it) }
                    Field("Set code · e.g. mh3", f.set) { f = f.copy(set = it) }
                    Section("Legal in")
                    val i = FORMATS.indexOfFirst { it.first == f.format }
                    FORMATS.chunked(3).forEachIndexed { row, chunk ->
                        T1Segmented(chunk.map { it.second }, if (i / 3 == row) i % 3 else -1) { f = f.copy(format = chunk[it].first) }
                    }
                    val q = f.query
                    Notice(q.ifEmpty { "Fill any field. Everything but card text searches the card data on this phone." })
                }
                BigAction("Search", enabled = f.query.isNotEmpty()) {
                    Telemetry.capture("advanced_search_used", mapOf("text" to f.text.isNotBlank(), "colors" to f.colors.size,
                        "mv" to f.mv.isNotBlank(), "rarity" to f.rarities.size, "set" to f.set.isNotBlank(), "format" to f.format))
                    onApply(f.query)
                }
            }
        }
    }
}

@Composable
private fun Field(label: String, value: String, onChange: (String) -> Unit) {
    Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) { T1TextField(value, onChange, label = label) }
}

@Composable
private fun Toggles(keys: List<Char>, selected: Set<Char>, label: (Char) -> String, onChange: (Set<Char>) -> Unit) {
    Row(Modifier.fillMaxWidth().background(T1.bg), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        keys.forEach { k ->
            val on = k in selected
            Box(Modifier.weight(1f).background(if (on) T1.text else T1.surface).border(1.dp, if (on) T1.text else T1.disabled)
                .clickable {
                    // Colorless and colors don't mix.
                    onChange(if (on) selected - k else (if (k == 'C') emptySet() else selected - 'C') + k)
                }.padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
                Label(label(k), color = if (on) T1.bg else T1.text)
            }
        }
    }
}
