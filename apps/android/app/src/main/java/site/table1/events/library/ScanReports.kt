package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.BuildConfig
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.theme.T1

/* Scan reports. Nobody is asked to report a bad scan: what people already do says it.
   - Changed the printing of a scanned card → wrong_printing, at once.
   - Deleted a scanned card → removed; if a card is then added by hand within 3 minutes, that card is the answer
     and it goes as wrong_card instead (the same card added back is a duplicate deleted, and nothing is sent).
   - Closed the scanner with nothing taken, then added a card by hand within 3 minutes → missed.
   Each carries the OCR lines of the frames the matcher saw (scan_report), and becomes a matcher test case in
   testdata/scan/reports/. Text only, never images. On by default; Account → Improve scanning turns it off.
   Changing the finish isn't reported: the camera can't tell foil. Same as iOS (contract/trades-2026-10-16.md). */

/** The last few frames' OCR lines, oldest first: the matcher's input up to a take. */
class ScanFrames {
    val frames = ArrayDeque<List<String>>()
    /** The last frames that had any text (what a miss is reported with). */
    val withText = ArrayDeque<List<String>>()
    /** Since the last take: frames with text that named no card, the last few of them kept. */
    var unnamed = 0
        private set
    val unnamedFrames = ArrayDeque<List<String>>()

    fun add(lines: List<String>, named: Boolean = false) {
        val f = lines.take(80)
        frames.addLast(f)
        while (frames.size > KEEP) frames.removeFirst()
        if (f.isNotEmpty()) {
            withText.addLast(f)
            while (withText.size > KEEP) withText.removeFirst()
            if (!named) {
                unnamed++
                unnamedFrames.addLast(f)
                while (unnamedFrames.size > KEEP) unnamedFrames.removeFirst()
            }
        }
    }

    /** A card was taken: what came before it was read. */
    fun took() { unnamed = 0; unnamedFrames.clear() }

    fun clear() { frames.clear(); withText.clear(); took() }

    companion object {
        const val KEEP = 6
        /** About 2 s of card text naming nothing: a card the scanner couldn't read. */
        const val MISSED = 10
    }
}

object ScanReports {
    const val KEY = "scan.reports"
    private const val WINDOW_MS = 180_000L
    private val prefs get() = T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE)
    var enabled: Boolean
        get() = prefs.getBoolean(KEY, true)
        set(v) { prefs.edit().putBoolean(KEY, v).apply() }

    enum class Kind(val wire: String) { WrongCard("wrong_card"), WrongPrinting("wrong_printing"), Removed("removed"), Missed("missed") }

    /** A deletion or miss waiting to learn which card it really was. */
    private class Pending(val kind: Kind, val frames: List<List<String>>, val matched: ScannedCard.Matched?,
                          val ownedOnly: Boolean, val at: Long)

    private val pending = ArrayList<Pending>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** The user changed a scanned card's printing. */
    fun printingChanged(card: ScannedCard, toCardId: String, ownedOnly: Boolean) {
        val m = card.matched ?: return
        if (m.cardId == toCardId) return
        send(Kind.WrongPrinting, card.frames, m, toCardId, ownedOnly)
    }

    /** The user deleted a scanned card. */
    fun removed(card: ScannedCard, ownedOnly: Boolean) {
        if (!enabled) return
        val m = card.matched ?: return
        hold(Pending(Kind.Removed, card.frames, m, ownedOnly, System.currentTimeMillis()))
    }

    /** The scanner closed. Nothing taken but text seen, or card text naming nothing for a while since the last take
     *  (an old card it couldn't read, between ones it could): the next card added by hand is probably the one it missed. */
    fun scannerClosed(taken: Int, frames: ScanFrames, ownedOnly: Boolean) {
        if (!enabled) return
        val missed = when {
            taken == 0 && frames.withText.isNotEmpty() -> frames.withText
            frames.unnamed >= ScanFrames.MISSED -> frames.unnamedFrames
            else -> return
        }
        hold(Pending(Kind.Missed, missed.toList(), null, ownedOnly, System.currentTimeMillis()))
    }

    /** A card was added by hand (collection +1, a trade line picked by search). Answers the oldest open deletion or miss. */
    fun addedByHand(cardId: String) = synchronized(pending) {
        expire()
        val p = pending.removeFirstOrNull() ?: return
        if (p.kind == Kind.Removed) {
            if (p.matched?.cardId == cardId) return // put back the same printing: a duplicate was deleted
            send(Kind.WrongCard, p.frames, p.matched, cardId, p.ownedOnly)
        } else {
            send(Kind.Missed, p.frames, null, cardId, p.ownedOnly)
        }
    }

    private fun hold(p: Pending) {
        synchronized(pending) { expire(); pending.add(p) }
        scope.launch {
            delay(WINDOW_MS + 1000)
            synchronized(pending) { expire() }
        }
    }

    /** Deletions nobody followed with a card by hand go as plain removals; such misses are dropped (no answer). */
    private fun expire() {
        val now = System.currentTimeMillis()
        val old = pending.filter { now - it.at > WINDOW_MS }
        pending.removeAll(old)
        for (p in old) if (p.kind == Kind.Removed) send(Kind.Removed, p.frames, p.matched, null, p.ownedOnly)
    }

    /** Fire and forget: a failed report is dropped and never gets in the way of scanning. */
    private fun send(kind: Kind, frames: List<List<String>>, matched: ScannedCard.Matched?, corrected: String?, ownedOnly: Boolean) {
        if (!enabled) return
        val params = buildJsonObject {
            put("p_kind", kind.wire)
            put("p_platform", "android")
            put("p_frames", buildJsonArray { for (f in frames) add(buildJsonArray { for (l in f) add(kotlinx.serialization.json.JsonPrimitive(l)) }) })
            if (matched != null) put("p_matched_card_id", matched.cardId) else put("p_matched_card_id", JsonNull)
            put("p_matched_exact", matched?.exact ?: false)
            if (corrected != null) put("p_corrected_card_id", corrected) else put("p_corrected_card_id", JsonNull)
            put("p_app_version", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            CatalogStore.db?.version?.let { put("p_pack_version", it) } ?: put("p_pack_version", JsonNull)
            put("p_owned_only", ownedOnly)
        }
        scope.launch {
            withContext(Dispatchers.IO) { runCatching { T1App.supabase.postgrest.rpc("scan_report", params) } }
        }
    }
}

/** A scanned card's printings: tap one to change it. Owned-only (Trades: what you give) lists only printings you own. */
@Composable
fun ScanPrintingScreen(card: ScannedCard, owned: Map<String, Set<String>>?, onPick: (CatalogPrinting) -> Unit, onClose: () -> Unit) {
    var printings by remember { mutableStateOf<List<CatalogPrinting>>(emptyList()) }
    LaunchedEffect(card.oracle.idx) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        printings = withContext(Dispatchers.IO) {
            db.printings(card.oracle.idx).let { all -> if (owned == null) all else all.filter { it.cardId in owned } }
        }
    }
    Box(Modifier.fillMaxSize().background(T1.bg)) {
        T1Screen {
            Bar("Printing", subtitle = card.oracle.name, onBack = onClose)
            Hairlines(Modifier.weight(1f)) {
                items(printings, key = { it.cardId }) { p ->
                    val current = p.cardId == card.printing.cardId
                    val detail = listOfNotNull(CatalogPack.RARITY_NAME[p.rarity], p.releasedAt.take(4).ifEmpty { null },
                        if (p.original) "Original" else null, if (p.lang == "en") null else p.lang.uppercase()).joinToString(" · ")
                    Row(Modifier.fillMaxWidth().background(T1.surface).clickable { if (current) onClose() else onPick(p) }
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        CardArt(p, 36.dp)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(p.setLabel, color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, maxLines = 1)
                            Label(detail)
                        }
                        Label(if (current) "Current" else "Pick", color = if (current) T1.disabled else T1.text)
                    }
                }
            }
        }
    }
}
