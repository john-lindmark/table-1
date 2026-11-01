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
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.key
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
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
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
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
import site.table1.events.ui.components.FullScreenDialog
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
    /**
     * The language the copy goes in as: its printing's when that isn't English, else the language of the printed
     * name read (Languages.forScan), else the one picked for adds.
     */
    val lang: String = "en",
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
    /** The row whose language is being changed; the camera is off meanwhile, like `fixing`. */
    var languageFor by remember { mutableStateOf<String?>(null) }
    val cancel = {
        ScanReports.scannerClosed(taken, frames, owned != null)
        onCancel()
    }

    val view = LocalView.current
    /**
     * One frame's lines; true when they name a card. ML Kit finds no card in the frame on Android, so the text must
     * look like a card's: a type line, or a set code and number that agree with the name (CardMatcher.hasTypeLine).
     */
    fun see(lines: List<String>, border: ScanBorder): Boolean {
        val m = matcher ?: return false
        val hit = m.match(lines, border)?.takeIf { it.exact || CardMatcher.hasTypeLine(lines) }
        frames.add(lines, named = hit != null)
        reading = hit?.oracle?.name
        val take = steady.feed(hit) ?: return hit != null
        val o = hit?.oracle ?: return false
        frames.took()
        m.took()
        taken++
        cards.add(0, ScannedCard(oracle = o, printing = take.first, finish = m.defaultFinish(take.first),
            condition = if (owned == null) condition else "NM", exact = take.second,
            frames = frames.frames.toList(), matched = ScannedCard.Matched(take.first.cardId, take.second),
            // Owned-only scans (giving in a trade) keep the owned copy's language.
            lang = if (owned == null) Languages.forScan(take.first.lang, hit.langs, Languages.addLang) else Languages.forNew(take.first.lang, Languages.addLang)))
        view.performHapticFeedback(if (android.os.Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.VIRTUAL_KEY)
        return true
    }

    Dialog(onDismissRequest = cancel, properties = FullScreenDialog) {
        val fix = fixing?.let { id -> cards.firstOrNull { it.id == id } }
        val langCard = languageFor?.let { id -> cards.firstOrNull { it.id == id } }
        if (langCard != null) {
            // The camera is off while the picker is open, like `fixing`, so nothing is taken behind it.
            val close = { languageFor = null; steady = ScanSteadiness(); frames.clear() }
            Box(Modifier.fillMaxSize().background(T1.bg))
            LanguagePicker(langCard.lang, langCard.oracle.name, onClose = close) { lang ->
                val at = cards.indexOfFirst { it.id == langCard.id }
                if (at >= 0) cards[at] = langCard.copy(lang = lang)
            }
        } else if (fix != null) {
            val close = { fixing = null; steady = ScanSteadiness(); frames.clear() }
            ScanPrintingScreen(fix, owned, onPick = { p ->
                ScanReports.printingChanged(fix, p.cardId, owned != null)
                matcher?.picked(p)
                val at = cards.indexOfFirst { it.id == fix.id }
                if (at >= 0) cards[at] = fix.copy(printing = p, fixed = true, lang = if (p.lang != "en") p.lang else fix.lang,
                    finish = if (p.finishList.any { it.wire == fix.finish }) fix.finish else matcher?.defaultFinish(p) ?: fix.finish)
                close()
            }, onClose = close)
        } else Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar(title, subtitle = if (cards.isEmpty()) (if (owned == null) "Hold a card flat in the frame" else "Matching cards you own")
                    else "${cards.size} scanned", onBack = cancel)
                when {
                    !granted -> {
                        Notice(if (asked) "Camera access is off. Allow it for Table 1 in Settings, or search by name instead."
                            else "Asking for the camera…", error = asked)
                        Box(Modifier.weight(1f))
                    }
                    cat.phase != "ready" -> {
                        CatalogStatus(cat)
                        Box(Modifier.weight(1f))
                    }
                    // The camera takes whatever the header, condition picker, scanned list and footer leave.
                    else -> Box(Modifier.fillMaxWidth().weight(1f).clipToBounds()) {
                        CameraText { lines, border -> see(lines, border) }
                        ScanGuide(reading)
                    }
                }
                if (owned == null) {
                    T1Segmented(Conditions.all, Conditions.all.indexOf(condition).coerceAtLeast(0)) { i ->
                        condition = Conditions.all[i]
                        prefs.edit().putString("addCondition", condition).apply()
                    }
                }
                if (cards.isNotEmpty()) {
                    // Sized to its rows, up to about three, so the camera keeps most of the screen.
                    Column(Modifier.fillMaxWidth().heightIn(max = 210.dp).verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        for (c in cards) key(c.id) { ScanRow(c, owned != null,
                            onPrinting = { fixing = c.id },
                            onLanguage = { languageFor = c.id },
                            onFinish = { next -> val at = cards.indexOfFirst { it.id == c.id }; if (at >= 0) cards[at] = c.copy(finish = next) },
                            onRemove = { ScanReports.removed(c, owned != null); cards.removeAll { it.id == c.id } }) }
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
/** Space kept above and below the guide box for its tips when the camera view's height limits it (iOS: 96 pt). */
private val GUIDE_MARGIN = 96.dp

/** One scanned card: tap it to change the printing; language, finish (when there's a choice) and remove beside it. */
@Composable
private fun ScanRow(c: ScannedCard, ownedOnly: Boolean, onPrinting: () -> Unit, onLanguage: () -> Unit, onFinish: (String) -> Unit, onRemove: () -> Unit) {
    val finishes = c.printing.finishList
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        Box(Modifier.weight(1f)) {
            // Tap the card to change its printing (a misread set code or collector number).
            CardRow(c.printing, c.oracle.name, listOfNotNull(c.printing.setLabel, Finish.of(c.finish)?.label,
                if (!ownedOnly) c.condition else null, if (!ownedOnly && c.lang != "en") c.lang.uppercase() else null,
                if (c.exact || c.fixed) null else "Check printing").joinToString(" · "),
                onClick = onPrinting, finish = c.finish) {
                Label("Printing", color = if (c.exact || c.fixed) T1.muted else T1.text)
            }
        }
        // The language: the printing's or the printed name's the scanner read, else the add default. Owned-only scans
        // (giving in a trade) keep the owned copy's language.
        if (!ownedOnly) Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable(onClick = onLanguage)
            .semantics { contentDescription = "Language, ${Languages.name(c.lang)}" }
            .padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
            Label(c.lang.uppercase(), color = T1.text)
        }
        if (finishes.size > 1) {
            // Foil can't be told from the camera: tap to switch.
            Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable {
                val i = finishes.indexOfFirst { it.wire == c.finish }
                onFinish(finishes[(i + 1) % finishes.size].wire)
            }.padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
                Label(Finish.of(c.finish)?.label ?: c.finish, color = T1.text)
            }
        }
        Box(Modifier.width(52.dp).fillMaxHeight().background(T1.surfaceHover).clickable(onClick = onRemove)
            .semantics { contentDescription = "Remove" }, contentAlignment = Alignment.Center) {
            Text("×", color = T1.text, fontFamily = T1.mono, fontSize = 20.sp)
        }
    }
}

/**
 * What to point at: a card-sized outline (the box the scanner reads inside, ScanRegion) with where it reads (the
 * name at the top, the set code and collector number at the bottom left), a tip above and below. The outline and
 * the top tip turn accent while a name is being read. Same as iOS.
 */
@Composable
private fun ScanGuide(reading: String?) {
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val b = with(density) { ScanRegion.viewBox(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat(), GUIDE_MARGIN.toPx()) }
        val line = if (reading == null) T1.text.copy(alpha = 0.7f) else T1.accent
        with(density) {
            val top = b.y.toDp(); val left = b.x.toDp(); val w = b.w.toDp(); val h = b.h.toDp()
            Box(Modifier.offset(left, top).size(w, h).border(1.dp, line).padding(8.dp)) {
                GuideMark("Name", Modifier.align(Alignment.TopStart))
                GuideMark("Set · number", Modifier.align(Alignment.BottomStart))
            }
            GuideTip(reading ?: "One card, upright, filling the outline", if (reading == null) T1.text else T1.accent,
                Modifier.align(Alignment.TopCenter).offset(y = top - 12.dp)
                    .layout { m, c -> val p = m.measure(c); layout(p.width, 0) { p.place(0, -p.height) } })
            GuideTip("Light from above, no glare", T1.muted, Modifier.align(Alignment.TopCenter).offset(y = top + h + 12.dp))
        }
    }
}

@Composable
private fun GuideTip(text: String, color: Color, modifier: Modifier) =
    Label(text, modifier.widthIn(max = 320.dp).background(T1.bg.copy(alpha = 0.8f)).padding(horizontal = 8.dp, vertical = 4.dp), color = color)

@Composable
private fun GuideMark(text: String, modifier: Modifier) =
    Label(text, modifier.background(T1.bg.copy(alpha = 0.6f)).padding(horizontal = 6.dp, vertical = 2.dp))

@Composable
private fun CameraText(onLines: (List<String>, ScanBorder) -> Boolean) {
    val context = LocalContext.current
    /** The preview's size in px (main thread writes it), to place the guide box in the image. */
    val viewSize = remember { java.util.concurrent.atomic.AtomicReference(0f to 0f) }
    val margin = with(LocalDensity.current) { GUIDE_MARGIN.toPx() }
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
    // Whether the main thread is still matching the last frame handed to it: a frame read meanwhile is dropped like
    // a late camera frame, so a slow match never builds a backlog that lags the rest of the session (2026-10-31).
    val matching = remember { java.util.concurrent.atomic.AtomicBoolean(false) }
    // Keep the screen on while the camera is reading.
    val screen = LocalView.current
    DisposableEffect(screen) {
        screen.keepScreenOn = true
        onDispose { screen.keepScreenOn = false }
    }
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
    fun fed(lines: List<String>, border: ScanBorder) {
        language.feed(matched = callback.value(lines, border), text = lines.isNotEmpty())
        reading.set(language.mode)
    }
    fun feedOnMain(lines: List<String>, border: ScanBorder) {
        if (!matching.compareAndSet(false, true)) return
        ContextCompat.getMainExecutor(context).execute { try { fed(lines, border) } finally { matching.set(false) } }
    }
    /**
     * The border colour read along the guide box from the frame's luma plane, before the frame goes to ML Kit (624
     * byte reads, microseconds): Alpha and Beta are black, Unlimited and Revised white (ScanBorder). The guide is in the
     * upright image; the raw image needs `rotation` degrees to show upright (ScanBorder.rawPixel).
     */
    fun border(media: android.media.Image, rotation: Int): ScanBorder {
        val upright = rotation % 180 != 0
        val iw = (if (upright) media.height else media.width).toFloat()
        val ih = (if (upright) media.width else media.height).toFloat()
        val (vw, vh) = viewSize.get()
        if (vw <= 0 || vh <= 0 || media.format != android.graphics.ImageFormat.YUV_420_888) return ScanBorder.UNKNOWN
        val n = ScanRegion.normalized(ScanRegion.viewBox(vw, vh, margin), vw, vh, iw, ih)
        val guide = Box(n.x * iw, n.y * ih, n.w * iw, n.h * ih)
        val plane = media.planes[0]
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val rw = media.width
        val rh = media.height
        val maxX = iw.toInt() - 1
        val maxY = ih.toInt() - 1
        return ScanBorder.classify(ScanBorder.samples(guide) { x, y ->
            val (rx, ry) = ScanBorder.rawPixel(x.toInt().coerceIn(0, maxX), y.toInt().coerceIn(0, maxY), rotation, rw, rh)
            buffer.get(ry * rowStride + rx * pixelStride).toInt() and 0xFF
        })
    }
    AndroidView(factory = { ctx ->
        // TextureView ("compatible"): a SurfaceView punches through the dialog's window, so the preview drew outside
        // its box and over the guide.
        val view = PreviewView(ctx).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        val future = ProcessCameraProvider.getInstance(ctx)
        future.addListener({
            val provider = future.get()
            // Both 4:3, so the guide maps onto the analysed image as it shows in the preview; 1280×960 for analysis
            // (CameraX's 640×480 default leaves the set code and collector number a few pixels tall).
            val ratio = AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY
            val preview = Preview.Builder().setResolutionSelector(ResolutionSelector.Builder().setAspectRatioStrategy(ratio).build())
                .build().also { it.surfaceProvider = view.surfaceProvider }
            val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setResolutionSelector(ResolutionSelector.Builder().setAspectRatioStrategy(ratio)
                    .setResolutionStrategy(ResolutionStrategy(android.util.Size(1280, 960), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                    .build())
                .build()
            analysis.setAnalyzer(executor) { proxy ->
                val media = proxy.image
                if (media == null) { proxy.close(); return@setAnalyzer }
                val border = runCatching { border(media, proxy.imageInfo.rotationDegrees) }.getOrDefault(ScanBorder.UNKNOWN)
                recognizer(reading.get()).process(InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees))
                    .addOnSuccessListener { text ->
                        // Only the text inside the guide box: a keyboard, a screen or another card beside it can't name a
                        // card. ML Kit finds no card rectangle on Android, so this is the "no card found" rule.
                        val upright = proxy.imageInfo.rotationDegrees % 180 != 0
                        val iw = (if (upright) proxy.height else proxy.width).toFloat()
                        val ih = (if (upright) proxy.width else proxy.height).toFloat()
                        val (vw, vh) = viewSize.get()
                        val guide = if (vw > 0 && vh > 0) ScanRegion.normalized(ScanRegion.viewBox(vw, vh, margin), vw, vh, iw, ih) else null
                        val lines = text.textBlocks.flatMap { it.lines }
                            .filter { l -> l.boundingBox?.let { b -> ScanRegion.readsText(guide, b.exactCenterX() / iw, b.exactCenterY() / ih) } ?: false }
                            .sortedBy { it.boundingBox?.top ?: 0 }.map { it.text }
                        feedOnMain(lines, border)
                    }
                    // A CJK model still downloading (Play services fetches it on first use) fails: a miss, so the next
                    // recognizer gets the next frame.
                    .addOnFailureListener { feedOnMain(emptyList(), ScanBorder.UNKNOWN) }
                    .addOnCompleteListener { proxy.close() }
            }
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            }
        }, ContextCompat.getMainExecutor(ctx))
        view
    }, modifier = Modifier.fillMaxSize().onSizeChanged { viewSize.set(it.width.toFloat() to it.height.toFloat()) }, onRelease = {
        runCatching { ProcessCameraProvider.getInstance(context).get().unbindAll() }
    })
}
