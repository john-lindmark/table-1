package site.table1.events.library

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import kotlinx.coroutines.launch
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1FullScreenDialog
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Card language (contract/card-language-2026-10-19.md). Every owned copy, binder copy and trade line has a language
   (Scryfall's codes); it can be changed wherever such a copy shows. Changing owned copies moves them to the new
   language in the same places (binders, Unsorted), as one undoable batch. Same rules as iOS `Languages.swift`. */

object Languages {
    /** Scryfall's language codes: the eleven most printed first, then the rest. */
    val all = listOf(
        "en" to "English", "de" to "German", "fr" to "French", "it" to "Italian", "es" to "Spanish", "pt" to "Portuguese",
        "ja" to "Japanese", "ko" to "Korean", "ru" to "Russian", "zhs" to "Chinese Simplified", "zht" to "Chinese Traditional",
        "he" to "Hebrew", "la" to "Latin", "grc" to "Ancient Greek", "ar" to "Arabic", "sa" to "Sanskrit", "ph" to "Phyrexian",
        "qya" to "Quenya",
    )
    const val COMMON = 11

    fun name(code: String) = all.firstOrNull { it.first == code }?.second ?: code.uppercase()

    /** The language new copies go in as: a non-English printing is in its own language; otherwise the one picked for adds. */
    fun forNew(printingLang: String, picked: String) = if (printingLang != "en") printingLang else picked

    /**
     * The language a scanned copy goes in as: a non-English printing's own; else the one the card's text says
     * ([read]: the code by its set code, or the languages of the printed name read; the one picked for adds when
     * that's one of them, a name several languages print alike); else the one picked. Empty [read] doesn't tell.
     */
    fun forScan(printingLang: String, read: List<String>, picked: String) = when {
        printingLang != "en" -> printingLang
        read.isEmpty() || picked in read -> picked
        else -> read[0]
    }

    private val prefs get() = T1App.instance.getSharedPreferences("library", Context.MODE_PRIVATE)

    /** The language picked for new copies (shared by card detail, binder adds, the scanner and trades). */
    var addLang: String
        get() = prefs.getString("addLang", "en") ?: "en"
        set(v) = prefs.edit().putString("addLang", v).apply()
}

object LanguageChange {
    /**
     * Moves `qty` copies of an item to another language, each copy staying where it is: from `from` when given (a binder
     * id or [UNSORTED]), else Unsorted first, then binders in the order given. Null when nothing would change.
     */
    fun ops(item: CollectionItem, places: List<Pair<String, Int>>, to: String, qty: Int, from: String? = null): List<CollectionOp>? {
        if (to == item.lang || qty <= 0 || qty > item.qty) return null
        val order = if (from != null) places.filter { it.first == from }
            else places.filter { it.first == UNSORTED } + places.filter { it.first != UNSORTED }
        var left = qty
        val ops = mutableListOf<CollectionOp>()
        for ((place, have) in order) {
            if (left <= 0) break
            val n = minOf(left, have)
            if (n <= 0) continue
            val binderId = if (place == UNSORTED) null else place
            ops.add(CollectionOp(item.cardId, item.finish, item.condition, item.lang, delta = -n, binderId = binderId))
            ops.add(CollectionOp(item.cardId, item.finish, item.condition, to, delta = n, binderId = binderId))
            left -= n
        }
        return if (left == 0) ops else null
    }
}

/** Every language, current one marked; picking closes it (picking the current one changes nothing). */
@Composable
fun LanguagePicker(current: String, subtitle: String? = null, onClose: () -> Unit, onPick: (String) -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("language_picker") }
    T1FullScreenDialog(onDismissRequest = onClose) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Language", subtitle = subtitle, onBack = onClose)
                Hairlines(Modifier.weight(1f)) {
                    itemsIndexed(Languages.all, key = { _, l -> l.first }) { i, (code, name) ->
                        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            if (i == Languages.COMMON) Section("Other")
                            ListRow(name, code.uppercase(), onClick = { onClose(); if (code != current) onPick(code) }) {
                                if (code == current) Label("Selected", color = T1.accent)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** "Language · English" with Change: what a copy is in, and the way to change it. */
@Composable
fun LanguageRow(lang: String, title: String = "Language", onClick: () -> Unit) {
    ListRow("$title · ${Languages.name(lang)}", onClick = onClick) { Label("Change", color = T1.text) }
}

/** The language new copies go in as, with its picker. */
@Composable
fun NewCopiesLanguageRow(onChange: (String) -> Unit = {}) {
    var lang by remember { mutableStateOf(Languages.addLang) }
    var picking by remember { mutableStateOf(false) }
    LanguageRow(lang, "New copies in") { picking = true }
    if (picking) LanguagePicker(lang, "For new copies", onClose = { picking = false }) { lang = it; Languages.addLang = it; onChange(it) }
}

/**
 * Card detail → a copy you own → Language: pick, then "One copy" or "All N copies" when there are several. Copies stay
 * where they are (Unsorted first, then binders), as one batch the caller can undo.
 */
@Composable
fun OwnedLanguageRow(item: CollectionItem, label: String, binders: BindersState, onDone: (String, String) -> Unit, onError: (String?) -> Unit) {
    val scope = rememberCoroutineScope()
    var picking by remember { mutableStateOf(false) }
    var asking by remember { mutableStateOf<String?>(null) }
    fun run(lang: String, n: Int) {
        val ops = LanguageChange.ops(item, PrintingChange.places(item, binders).map { it.place to it.qty }, lang, n) ?: return
        scope.launch {
            runCatching { CollectionStore.apply(ops) }
                .onSuccess {
                    Telemetry.capture("language_changed", mapOf("where" to "owned", "copies" to n))
                    onDone(it.batchId, "Moved $n $label to ${Languages.name(lang)}")
                }
                .onFailure { onError(it.message) }
        }
    }
    LanguageRow(item.lang) { picking = true }
    if (picking) LanguagePicker(item.lang, label, onClose = { picking = false }) { lang -> if (item.qty <= 1) run(lang, 1) else asking = lang }
    asking?.let { lang ->
        T1Menu("Mark as ${Languages.name(lang)}", listOf(
            T1MenuItem("One copy") { run(lang, 1) },
            T1MenuItem("All ${item.qty} copies") { run(lang, item.qty) },
        )) { asking = null }
    }
}
