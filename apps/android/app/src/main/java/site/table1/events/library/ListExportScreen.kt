package site.table1.events.library

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.io.File

/* Export for a deck or cube (contract/shared-lists-grouping-2026-10-20.md §2): the list as text first, in the format
   picked above it, then the ways out: to Arena (copied: Arena imports from the clipboard) and MTGO (a .txt file) for
   decks, to Cube Cobra (a CSV file) for cubes, and Download / Copy of the text shown. Your own lists and decks or cubes
   shared with you on a profile use the same screen. Output is ListExport's, unchanged. */

/** The picker's label. */
val ListExport.Format.short: String
    get() = when (this) {
        ListExport.Format.Arena -> "Arena"
        ListExport.Format.Moxfield -> "Moxfield"
        ListExport.Format.Mtgo -> "MTGO"
        ListExport.Format.Text -> "Text"
        ListExport.Format.CubeCobra -> "Cube Cobra"
    }

fun leftOutNote(left: Int): String? =
    if (left > 0) "$left card${if (left == 1) "" else "s"} newer than the card data ${if (left == 1) "was" else "were"} left out." else null

/** `from`: own / profile (telemetry). */
@Composable
fun ListExportScreen(name: String, kind: ListKind, entries: List<ListEntry>, from: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val cat by CatalogStore.state.collectAsState()
    val formats = remember(kind) { listOf(ListExport.Format.Text) + ListExport.Format.formats(kind).filter { it != ListExport.Format.Text } }
    var format by remember { mutableStateOf(ListExport.Format.Text) }
    var texts by remember { mutableStateOf<Map<ListExport.Format, String>>(emptyMap()) }
    var cards by remember { mutableIntStateOf(0) }
    var left by remember { mutableIntStateOf(0) }
    var note by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(cat.generation, entries) {
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return@LaunchedEffect
        val (lines, l) = withContext(Dispatchers.Default) { ListExport.lines(entries, db) }
        texts = withContext(Dispatchers.Default) { formats.associateWith { ListExport.render(lines, kind, it) } }
        cards = lines.sumOf { it.qty }
        left = l
    }
    fun sent(f: ListExport.Format, how: String) =
        Telemetry.capture("list_exported", mapOf("kind" to kind.wire, "format" to f.wire, "cards" to cards, "left" to left, "from" to from, "how" to how))
    fun copy(f: ListExport.Format, done: String) {
        val text = texts[f] ?: return
        (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText(name, text))
        note = done
        error = null
        sent(f, "copy")
    }
    /** A file (.txt, or .csv for Cube Cobra) to the share sheet: save it, or send it to another app. */
    fun download(f: ListExport.Format) {
        val text = texts[f] ?: return
        scope.launch {
            runCatching { shareFile(context, text, ListExport.fileName(name, kind, f)) }
                .onSuccess { note = null; error = null; sent(f, "download") }
                .onFailure { error = it.message }
        }
    }

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Export", name, onBack = onClose)
                T1Segmented(formats.map { it.short }, formats.indexOf(format)) { format = formats[it]; note = null }
                Notice(format.detail)
                SelectionContainer(Modifier.weight(1f).fillMaxWidth().background(T1.surface)) {
                    Text(texts[format] ?: if (CatalogStore.db == null) "Waiting for the card data…" else "",
                        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()).padding(16.dp),
                        color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, lineHeight = 19.sp, softWrap = false)
                }
                error?.let { Notice(it, error = true) }
                (note ?: leftOutNote(left))?.let { Notice(it) }
                val ready = texts.isNotEmpty()
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    if (kind == ListKind.Deck) {
                        Ghost("To Arena", enabled = ready, accent = true) { copy(ListExport.Format.Arena, "Copied for MTG Arena. In Arena: Decks → Import.") }
                        Ghost("To MTGO", enabled = ready, accent = true) { download(ListExport.Format.Mtgo) }
                    } else {
                        Ghost("To Cube Cobra", enabled = ready, accent = true) { download(ListExport.Format.CubeCobra) }
                    }
                }
                Row(Modifier.fillMaxWidth().padding(bottom = 1.dp), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Download .${format.fileExtension ?: "txt"}", enabled = ready) { download(format) }
                    Ghost("Copy text", enabled = ready) { copy(format, "Copied.") }
                }
            }
        }
    }
}

/** Writes the text under the export FileProvider path and hands it to the share sheet. */
private suspend fun shareFile(context: Context, text: String, fileName: String) {
    val file = File(context.cacheDir, "export/lists/$fileName")
    withContext(Dispatchers.IO) {
        file.parentFile?.mkdirs()
        file.writeText(text)
    }
    val send = Intent(Intent.ACTION_SEND)
    send.type = if (fileName.endsWith(".csv")) "text/csv" else "text/plain"
    send.putExtra(Intent.EXTRA_STREAM, FileProvider.getUriForFile(context, "${context.packageName}.avatars", file))
    send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, fileName))
}
