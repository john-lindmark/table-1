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
)

/** Full-screen scanner used by Add cards and Trades. Collects cards until Done; nothing is written here. */
@Composable
fun CardScanOverlay(
    title: String,
    doneLabel: String,
    owned: Map<String, Set<String>>?,
    onDone: (List<ScannedCard>) -> Unit,
    onCancel: () -> Unit,
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
        value = CatalogStore.db?.let { db -> withContext(Dispatchers.Default) { CardMatcher(db, owned, ScanNames.shared(db)) } }
    }
    val steady = remember { ScanSteadiness() }

    fun see(lines: List<String>) {
        val m = matcher ?: return
        val hit = m.match(lines)
        reading = hit?.oracle?.name
        val taken = steady.feed(hit) ?: return
        val o = hit?.oracle ?: return
        cards.add(0, ScannedCard(oracle = o, printing = taken.first, finish = m.defaultFinish(taken.first),
            condition = if (owned == null) condition else "NM", exact = taken.second))
    }

    Dialog(onDismissRequest = onCancel, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar(title, subtitle = if (cards.isEmpty()) (if (owned == null) "Hold a card flat in the frame" else "Matching cards you own")
                    else "${cards.size} scanned", onBack = onCancel)
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
                                CardRow(c.printing, c.oracle.name, listOfNotNull(c.printing.setLabel, Finish.of(c.finish)?.label,
                                    if (owned == null) c.condition else null, if (c.exact) null else "Check printing").joinToString(" · "))
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
                            Box(Modifier.width(52.dp).fillMaxHeight().background(T1.surfaceHover).clickable { cards.removeAll { it.id == c.id } },
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

/** Camera preview that reads text (ML Kit, on device) and reports the lines, top of the frame first. */
@Composable
private fun CameraText(onLines: (List<String>) -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val callback = remember { mutableStateOf(onLines) }
    callback.value = onLines
    val executor = remember { Executors.newSingleThreadExecutor() }
    val recognizer = remember { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }
    DisposableEffect(Unit) {
        onDispose {
            recognizer.close()
            executor.shutdown()
        }
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
                recognizer.process(InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees))
                    .addOnSuccessListener { text ->
                        val lines = text.textBlocks.flatMap { it.lines }.sortedBy { it.boundingBox?.top ?: 0 }.map { it.text }
                        ContextCompat.getMainExecutor(context).execute { callback.value(lines) }
                    }
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
