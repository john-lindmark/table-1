package site.table1.events.ui.spots

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import site.table1.events.ui.components.Label
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/**
 * A feature spot (contract/feature-spots-2026-11-01.md): a piece of Table 1 worth showing, with copy and a phone shot
 * of the real screen. Read from assets/spots/spots.json, the folder marketing/bundle the app bundles (the same file
 * the web and iOS read), so copy changes there reach every placement.
 */
@Serializable
data class Spot(val key: String, val title: String, val headline: String, val body: String, val onboarding: Boolean = true)

object Spots {
    @Serializable
    data class Limits(val title: Int, val headline: Int, val body: Int)

    @Serializable
    data class File(val updated: String, val limits: Limits, val spots: List<Spot>)

    private val json = Json { ignoreUnknownKeys = true }

    /** How long a page stays before the carousel moves on by itself (until the first swipe). */
    const val DWELL_MS = 6_000L

    fun load(context: Context): File? = runCatching {
        json.decodeFromString<File>(context.assets.open("spots/spots.json").use { it.readBytes().toString(Charsets.UTF_8) })
    }.getOrNull()

    /** The sign-in carousel's pages, in the file's order. */
    fun onboarding(context: Context): List<Spot> = load(context)?.spots?.filter { it.onboarding } ?: emptyList()

    /** The spot's phone shot (780×1688), or null before the first shoot. */
    fun shot(context: Context, key: String): Bitmap? = runCatching {
        context.assets.open("spots/shots/$key.png").use { BitmapFactory.decodeStream(it) }
    }.getOrNull()

    /** The page after [page], wrapping; the carousel's timer uses it. */
    fun next(page: Int, count: Int): Int = if (count == 0) 0 else (page + 1) % count
}

/**
 * The sign-in screen's carousel: one page per onboarding spot (copy beside its shot), dots under it, moving on by
 * itself every few seconds until the person swipes. Sits between the mark and the sign-in buttons.
 */
@Composable
fun SpotsCarousel(spots: List<Spot>, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val state = rememberPagerState { spots.size }
    var swiped by remember { mutableStateOf(false) }
    LaunchedEffect(state) {
        snapshotFlow { state.isScrollInProgress }.collect { if (it) swiped = true }
    }
    LaunchedEffect(state, swiped) {
        if (swiped || spots.size < 2) return@LaunchedEffect
        while (true) {
            delay(Spots.DWELL_MS)
            if (swiped) break
            state.animateScrollToPage(Spots.next(state.currentPage, spots.size))
        }
    }
    LaunchedEffect(state) {
        var last = state.currentPage
        snapshotFlow { state.settledPage }.collect { page ->
            if (page != last && page in spots.indices) {
                Telemetry.capture("spot_viewed", mapOf("key" to spots[page].key, "index" to page, "swiped" to swiped))
                last = page
            }
        }
    }
    Column(modifier.fillMaxWidth().background(T1.surface)) {
        HorizontalPager(state, Modifier.weight(1f).fillMaxWidth()) { i ->
            val spot = spots[i]
            val shot = remember(spot.key) { Spots.shot(context, spot.key) }
            Row(Modifier.fillMaxSize().padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label(spot.title)
                    Text(spot.headline.uppercase(), color = T1.text, fontFamily = T1.mono, fontWeight = FontWeight.Bold, fontSize = 17.sp,
                        letterSpacing = 1.5.sp, lineHeight = 24.sp)
                    Text(spot.body, color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp, lineHeight = 18.sp)
                }
                if (shot != null) {
                    // The whole width of the phone shot, from its top, cut off at the bottom when the page is short.
                    Box(Modifier.width(132.dp).fillMaxHeight().clipToBounds(), contentAlignment = Alignment.TopCenter) {
                        Image(shot.asImageBitmap(), contentDescription = null, contentScale = ContentScale.FillWidth,
                            modifier = Modifier.fillMaxWidth().aspectRatio(shot.width.toFloat() / shot.height).border(1.dp, T1.bg))
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(bottom = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
            spots.indices.forEach { i ->
                val w by animateDpAsState(if (i == state.currentPage) 18.dp else 6.dp, label = "dot")
                Box(Modifier.width(w).height(3.dp).background(if (i == state.currentPage) T1.accent else T1.disabled))
            }
        }
        Spacer(Modifier.height(0.dp))
    }
}
