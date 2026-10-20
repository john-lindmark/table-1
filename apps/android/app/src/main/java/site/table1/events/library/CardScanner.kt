package site.table1.events.library

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.theme.T1
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/* Card scanning (camera). On-device only: ML Kit reads the text on the card, the name is matched against the
   local catalog pack, and the set code / collector number printed at the bottom picks the printing. A card is
   accepted once the same name has held steady across frames; it isn't taken again until it leaves the frame.
   The Scryfall API is never called per frame. Same rules as iOS (contract/trades-2026-10-16.md). */

data class ScannedCard(
    val id: String = UUID.randomUUID().toString(),
    val oracle: CatalogOracle,
    val printing: CatalogPrinting,
    val finish: String,
    val condition: String,
    /** Read from the card's set code and collector number, not a fallback to the default printing. */
    val exact: Boolean,
    /** The OCR lines of the frames that led to the take, oldest first (sent with a correction, ScanReports). */
    val frames: List<List<String>> = emptyList(),
    /** What the matcher picked; stays as it was when the user changes the printing. */
    val matched: Matched? = null,
    /** The user changed the printing: it's theirs, not a guess. */
    val fixed: Boolean = false,
) {
    data class Matched(val cardId: String, val exact: Boolean)
}

/** Full-screen scanner used by Add cards and Trades. Collects cards until Done; nothing is written here. */
@Composable
fun CardScanOverlay(
    title: String,
    doneLabel: String,
    owned: Map<String, Set<String>>?,
    onDone: (List<ScannedCard>) -> Unit,
    onCancel: () -> Unit,
    /** Owned-only: printing id → finishes in for-trade binders, preferred when the text doesn't settle the printing. */
    preferred: Map<String, Set<String>> = emptyMap(),
) {
    val context = LocalContext.current
    val cat by CatalogStore.state.collectAsState()
    val prefs = remember { T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE) }
    var condition by remember { mutableStateOf(prefs.getString("addCondition", "NM") ?: "NM") }
    val cards = remember { mutableStateListOf<ScannedCard>() }
    var reading by remember { mutableStateOf<String?>(null) }
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var asked by remember { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it; asked = true }
    LaunchedEffect(Unit) {
        CatalogStore.load(userInitiated = true)
        if (!granted) permission.launch(Manifest.permission.CAMERA)
    }
    // The matcher's name index takes a moment to build the first time, so it's built off the main thread.
    val matcher by produceState<CardMatcher?>(null, cat.generation) {
        value = CatalogStore.db?.let { db -> withContext(Dispatchers.Default) { CardMatcher(db, owned, ScanNames.shared(db), preferred) } }
    }
    var steady by remember { mutableStateOf(ScanSteadiness()) }
    val frames = remember { ScanFrames() }
    /** Cards taken this session, deleted ones included (a session with none is a miss if a card is then added by hand). */
    var taken by remember { mutableStateOf(0) }
    /** The row whose printing is being changed; the camera is off meanwhile, so nothing is taken behind it. */
    var fixing by remember { mutableStateOf<String?>(null) }
    val cancel = {
        ScanReports.scannerClosed(taken, frames, owned != null)
        onCancel()
    }

    /** One frame's lines; true when they name a card. */
    fun see(lines: List<String>): Boolean {
        val m = matcher ?: return false
        frames.add(lines)
        val hit = m.match(lines)
        reading = hit?.oracle?.name
        val take = steady.feed(hit) ?: return hit != null
        val o = hit?.oracle ?: return false
        taken++
        cards.add(0, ScannedCard(oracle = o, printing = take.first, finish = m.defaultFinish(take.first),
            condition = if (owned == null) condition else "NM", exact = take.second,
            frames = frames.frames.toList(), matched = ScannedCard.Matched(take.first.cardId, take.second)))
        return true
    }

    Dialog(onDismissRequest = cancel, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        val fix = fixing?.let { id -> cards.firstOrNull { it.id == id } }
        if (fix != null) {
            val close = { fixing = null; steady = ScanSteadiness(); frames.clear() }
            ScanPrintingScreen(fix, owned, onPick = { p ->
                ScanReports.printingChanged(fix, p.cardId, owned != null)
                val at = cards.indexOfFirst { it.id == fix.id }
                if (at >= 0) cards[at] = fix.copy(printing = p, fixed = true,
                    finish = if (p.finishList.any { it.wire == fix.finish }) fix.finish else matcher?.defaultFinish(p) ?: fix.finish)
                close()
            }, onClose = close)
        } else Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar(title, subtitle = if (cards.isEmpty()) (if (owned == null) "Hold a card flat in the frame" else "Matching cards you own")
                    else "${cards.size} scanned", onBack = cancel)
                when {
                    !granted -> Notice(if (asked) "Camera access is off. Allow it for Table 1 in Settings, or search by name instead."
                        else "Asking for the camera…", error = asked)
                    cat.phase != "ready" -> CatalogStatus(cat)
                    else -> Box(Modifier.fillMaxWidth().height(300.dp)) {
                        CameraText { see(it) }
                        reading?.let { Label(it, Modifier.align(Alignment.BottomStart).background(T1.bg).padding(8.dp), color = T1.text) }
                    }
                }
                if (owned == null) {
                    T1Segmented(Conditions.all, Conditions.all.indexOf(condition).coerceAtLeast(0)) { i ->
                        condition = Conditions.all[i]
                        prefs.edit().putString("addCondition", condition).apply()
                    }
                }
                Hairlines(Modifier.weight(1f)) {
                    items(cards, key = { it.id }) { c ->
                        val finishes = c.printing.finishList
                        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            Box(Modifier.weight(1f)) {
                                // Tap the card to change its printing (a misread set code or collector number).
                                CardRow(c.printing, c.oracle.name, listOfNotNull(c.printing.setLabel, Finish.of(c.finish)?.label,
                                    if (owned == null) c.condition else null, if (c.exact || c.fixed) null else "Check printing").joinToString(" · "),
                                    onClick = { fixing = c.id }, finish = c.finish) {
                                    Label("Printing", color = if (c.exact || c.fixed) T1.muted else T1.text)
                                }
                            }
                            if (finishes.size > 1) {
                                // Foil can't be told from the camera: tap to switch.
                                Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable {
                                    val i = finishes.indexOfFirst { it.wire == c.finish }
                                    val next = finishes[(i + 1) % finishes.size].wire
                                    val at = cards.indexOfFirst { it.id == c.id }
                                    if (at >= 0) cards[at] = c.copy(finish = next)
                                }.padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
                                    Label(Finish.of(c.finish)?.label ?: c.finish, color = T1.text)
                                }
                            }
                            Box(Modifier.width(52.dp).fillMaxHeight().background(T1.surfaceHover).clickable {
                                ScanReports.removed(c, owned != null)
                                cards.removeAll { it.id == c.id }
                            },
                                contentAlignment = Alignment.Center) {
                                Text("×", color = T1.text, fontFamily = T1.mono, fontSize = 20.sp)
                            }
                        }
                    }
                }
                BigAction(if (cards.isEmpty()) "Scan a card" else "$doneLabel ${cards.size}", enabled = cards.isNotEmpty(), accent = true) {
                    onDone(cards.toList())
                }
            }
        }
    }
}

/**
 * Camera preview that reads text (ML Kit, on device) and reports the lines, top of the frame first; `onLines` says
 * whether they named a card. ML Kit reads one script per recognizer and can't tell which a card is in, and nobody
 * picks a language: the Latin recognizer reads until text in view names no card for a while (ScanLanguage), then
 * the Japanese, Chinese and Korean ones a frame each in turn, keeping the one that names cards, and back to Latin
 * after a run of misses. One recognizer per frame; the CJK ones are made (and their models fetched by Play
 * services) only the first time they're needed.
 */
@Composable
private fun CameraText(onLines: (List<String>) -> Boolean) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val callback = remember { mutableStateOf(onLines) }
    callback.value = onLines
    val executor = remember { Executors.newSingleThreadExecutor() }
    val latin = remember { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }
    // Japanese first: its model also reads kanji. Made on the executor, the first time each is needed.
    val cjk = remember { arrayOfNulls<TextRecognizer>(3) }
    val language = remember { ScanLanguage(readers = cjk.size) }
    // ScanLanguage.mode, for the executor; fed on the main thread.
    val reading = remember { AtomicInteger(ScanLanguage.LATIN) }
    DisposableEffect(Unit) {
        onDispose {
            latin.close()
            executor.execute { cjk.forEach { it?.close() } }
            executor.shutdown()
        }
    }
    fun recognizer(mode: Int): TextRecognizer = if (mode == ScanLanguage.LATIN) latin else cjk[mode] ?: TextRecognition.getClient(
        when (mode) {
            0 -> JapaneseTextRecognizerOptions.Builder().build()
            1 -> ChineseTextRecognizerOptions.Builder().build()
            else -> KoreanTextRecognizerOptions.Builder().build()
        },
    ).also { cjk[mode] = it }
    fun fed(lines: List<String>) {
        language.feed(matched = callback.value(lines), text = lines.isNotEmpty())
        reading.set(language.mode)
    }
    AndroidView(factory = { ctx ->
        val view = PreviewView(ctx)
        val future = ProcessCameraProvider.getInstance(ctx)
        future.addListener({
            val provider = future.get()
            val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
            val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
            analysis.setAnalyzer(executor) { proxy ->
                val media = proxy.image
                if (media == null) { proxy.close(); return@setAnalyzer }
                recognizer(reading.get()).process(InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees))
                    .addOnSuccessListener { text ->
                        val lines = text.textBlocks.flatMap { it.lines }.sortedBy { it.boundingBox?.top ?: 0 }.map { it.text }
                        ContextCompat.getMainExecutor(context).execute { fed(lines) }
                    }
                    // A CJK model still downloading (Play services fetches it on first use) fails: a miss, so the next
                    // recognizer gets the next frame.
                    .addOnFailureListener { ContextCompat.getMainExecutor(context).execute { fed(emptyList()) } }
                    .addOnCompleteListener { proxy.close() }
            }
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            }
        }, ContextCompat.getMainExecutor(ctx))
        view
    }, modifier = Modifier.fillMaxSize(), onRelease = {
        runCatching { ProcessCameraProvider.getInstance(context).get().unbindAll() }
    })
}
