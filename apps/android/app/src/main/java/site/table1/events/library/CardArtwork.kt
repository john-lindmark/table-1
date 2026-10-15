package site.table1.events.library

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import site.table1.events.T1App
import site.table1.events.ui.components.Label
import site.table1.events.ui.theme.T1
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

// Card images from Scryfall's CDN (cards.scryfall.io: no rate limit, no API call), built for long lists:
//  - the smallest rendition that covers the drawn pixels: "small" (146 px wide, ~10 KB) for thumbnails,
//    "normal" (488 px) for the grid and card detail;
//  - decoded off the main thread with power-of-two sampling, so a 36 dp thumbnail holds a small bitmap;
//  - decoded bitmaps in a memory LRU sized to 1/8 of the heap, files in a 300 MB disk cache;
//  - at most 6 downloads at once, one per image however many rows ask.

/** Corner radius as a fraction of card width, measured from Scryfall's transparent PNG scans (2026-10-15):
 *  every printing 4.32% (≈2.7 mm), Alpha 6.99% (≈4.4 mm, a rounder cutting die), CE/IE square. */
object CardCorners {
    fun ratio(set: String): Float = when (set) {
        "lea" -> 0.0699f
        "ced", "cei" -> 0f
        else -> 0.0432f
    }
}

const val CARD_ASPECT = 488f / 680f

object CardImageLoader {
    private const val DISK_LIMIT = 300L shl 20

    private val memory = object : LruCache<String, ImageBitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }
    private val network = Semaphore(6)
    private val lock = Mutex()
    private val flights = HashMap<String, CompletableDeferred<ImageBitmap?>>()
    private val dir by lazy { File(T1App.instance.cacheDir, "card-images").apply { mkdirs() } }
    @Volatile private var trimmed = false

    fun size(px: Int) = if (px <= 146) "small" else if (px <= 488) "normal" else "large"
    private fun key(url: String, maxPx: Int) = "$maxPx|$url"

    fun cached(url: String, maxPx: Int): ImageBitmap? = memory.get(key(url, maxPx))

    suspend fun load(url: String, maxPx: Int): ImageBitmap? {
        val k = key(url, maxPx)
        memory.get(k)?.let { return it }
        var mine = false
        val flight = lock.withLock {
            flights[k] ?: CompletableDeferred<ImageBitmap?>().also { flights[k] = it; mine = true }
        }
        if (mine) {
            val result = runCatching { fetch(url, maxPx) }.getOrNull()
            result?.let { memory.put(k, it) }
            lock.withLock { flights.remove(k) }
            flight.complete(result)
        }
        return flight.await()
    }

    private suspend fun fetch(url: String, maxPx: Int): ImageBitmap? = withContext(Dispatchers.IO) {
        val name = MessageDigest.getInstance("SHA-1").digest(url.toByteArray()).joinToString("") { "%02x".format(it) }
        val file = File(dir, "$name.jpg")
        if (!file.exists()) {
            network.withPermit {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.setRequestProperty("User-Agent", "Table1Events/1.0 (table-1.site)")
                try {
                    if (conn.responseCode != 200) return@withContext null
                    val tmp = File(dir, "$name.part")
                    conn.inputStream.use { input -> tmp.outputStream().use { input.copyTo(it) } }
                    tmp.renameTo(file)
                } finally {
                    conn.disconnect()
                }
            }
            if (!trimmed) { trimmed = true; trimDisk() }
        } else {
            file.setLastModified(System.currentTimeMillis()) // keeps recently seen images on trim
        }
        decode(file, maxPx)?.asImageBitmap()
    }

    /** Decodes with the largest power-of-two sample that still covers `maxPx` on the long side. */
    private fun decode(file: File, maxPx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        val longSide = maxOf(bounds.outWidth, bounds.outHeight)
        if (longSide <= 0) return null
        var sample = 1
        while (longSide / (sample * 2) >= maxPx) sample *= 2
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            // JPEGs have no alpha; thumbnails don't need 32-bit color.
            inPreferredConfig = if (maxPx <= 220) Bitmap.Config.RGB_565 else Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeFile(file.path, opts)
    }

    /** Keeps the disk cache under its limit, dropping the least recently used files first. */
    private fun trimDisk() {
        val files = dir.listFiles()?.filter { it.extension == "jpg" } ?: return
        var total = files.sumOf { it.length() }
        if (total <= DISK_LIMIT) return
        for (f in files.sortedBy { it.lastModified() }) {
            if (total <= DISK_LIMIT * 9 / 10) break
            total -= f.length()
            f.delete()
        }
    }
}

/** A card image at a fixed width with the printing's real corner radius; flat placeholder until loaded. */
@Composable
fun CardArt(printing: CatalogPrinting?, width: Dp, modifier: Modifier = Modifier) {
    val density = LocalDensity.current
    val height = width / CARD_ASPECT
    val maxPx = with(density) { height.roundToPx() }
    val url = printing?.imageUrl(CardImageLoader.size(with(density) { width.roundToPx() }))
    val shape = RoundedCornerShape(width * CardCorners.ratio(printing?.set ?: ""))
    var image by remember(url) { mutableStateOf(url?.let { CardImageLoader.cached(it, maxPx) }) }
    LaunchedEffect(url) { if (url != null && image == null) image = CardImageLoader.load(url, maxPx) }
    Box(modifier.size(width, height).clip(shape).background(T1.bg)) {
        image?.let { Image(it, contentDescription = null, Modifier.size(width, height), contentScale = ContentScale.Crop) }
    }
}

/** A list row led by a card thumbnail; same type and spacing as ListRow. */
@Composable
fun CardRow(printing: CatalogPrinting?, title: String, detail: String? = null, onClick: (() -> Unit)? = null,
            trailing: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().background(T1.surface)
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        CardArt(printing, 36.dp)
        Column(Modifier.weight(1f)) {
            Text(title, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            detail?.let { Label(it) }
        }
        trailing()
    }
}

/** One grid cell: the image with a count tag inset from the rounded corner. */
@Composable
fun CardTile(printing: CatalogPrinting?, qty: Int, width: Dp, warn: Boolean = false, onClick: (() -> Unit)? = null) {
    Box(Modifier.width(width).let { if (onClick != null) it.clickable(onClick = onClick) else it }) {
        CardArt(printing, width)
        Text("$qty", Modifier.align(Alignment.BottomEnd).padding(width * 0.05f)
            .background(if (warn) T1.error else T1.bg).padding(horizontal = 6.dp, vertical = 2.dp),
            color = if (warn) T1.bg else T1.text, fontFamily = T1.mono, fontSize = 13.sp)
    }
}

/** A lazily built card grid that fills the width: three columns on a phone, more on wider screens. */
@Composable
fun CardGrid(modifier: Modifier = Modifier, content: LazyGridScope.(tileWidth: Dp) -> Unit) {
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val cols = maxOf(3, (maxWidth / 180.dp).toInt())
        val tile = (maxWidth - 1.dp * (cols - 1)) / cols
        LazyVerticalGrid(GridCells.Fixed(cols), horizontalArrangement = Arrangement.spacedBy(1.dp),
            verticalArrangement = Arrangement.spacedBy(1.dp)) { content(tile) }
    }
}

/** A full-width header cell inside a CardGrid. */
fun LazyGridScope.gridHeader(key: String, content: @Composable () -> Unit) {
    item(key = key, span = { GridItemSpan(maxLineSpan) }) { content() }
}
