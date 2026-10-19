package site.table1.events.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.storage.storage
import io.ktor.http.ContentType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.BuildConfig
import site.table1.events.T1App
import site.table1.events.ui.theme.T1
import java.io.ByteArrayOutputStream
import java.util.UUID

// Avatars (contract/avatars-2026-10-16.md): initials on a muted tile picked from the account id, or the
// player's photo from the public `avatars` bucket. Same rules on every platform.

object AvatarStyle {
    /** Muted tints near the surface's lightness: a quiet tile, never mistaken for the teal accent. */
    val palette: List<Long> = listOf(0x4A3F6B, 0x5B3E5A, 0x63414A, 0x5E4A38, 0x4D5236, 0x36524A, 0x3A4C66, 0x4B4B5E)

    /** First letter or digit of the first and last word; one word gives one letter; nothing gives "?". */
    fun initials(name: String): String {
        val firsts = name.split(Regex("\\s+")).mapNotNull { word ->
            var i = 0
            var found: String? = null
            while (i < word.length && found == null) {
                val cp = word.codePointAt(i)
                if (Character.isLetterOrDigit(cp)) found = String(Character.toChars(cp))
                i += Character.charCount(cp)
            }
            found
        }
        if (firsts.isEmpty()) return "?"
        return (if (firsts.size > 1) firsts.first() + firsts.last() else firsts.first()).uppercase()
    }

    /** The account id when there is one, so a player looks the same everywhere; a guest's name otherwise. */
    fun seed(userId: String?, name: String): String = userId?.lowercase() ?: name.trim().lowercase()

    /** FNV-1a 32-bit over the seed's UTF-8 bytes. */
    fun colorIndex(seed: String): Int {
        var h = 2166136261u
        for (b in seed.toByteArray(Charsets.UTF_8)) h = (h xor b.toUByte().toUInt()) * 16777619u
        return (h % palette.size.toUInt()).toInt()
    }

    fun color(userId: String?, name: String): Color = Color(0xFF000000 or palette[colorIndex(seed(userId, name))])
}

/** Which accounts have photos, read from `profiles` in batches for the ids on screen and kept for the session. */
object AvatarStore {
    /** user id → bucket path; a null value means "no photo" (asked already). */
    private val paths = mutableStateMapOf<String, String?>()
    private val pending = mutableSetOf<String>()
    private var flushing = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    fun path(userId: String): String? = paths[userId]

    fun url(path: String) = "${BuildConfig.SUPABASE_URL}/storage/v1/object/public/avatars/$path"

    @Serializable
    private data class Row(@SerialName("user_id") val userId: String, @SerialName("avatar_url") val avatarUrl: String? = null)

    fun want(userId: String) {
        if (paths.containsKey(userId) || userId in pending) return
        pending += userId
        if (flushing) return
        flushing = true
        scope.launch {
            // Let the rest of the list ask first, then one query.
            delay(30)
            try {
                while (pending.isNotEmpty()) {
                    val ids = pending.take(100)
                    // people() returns only accounts you have a reason to see (contract/privacy-lockdown-2026-10-18.md);
                    // anyone else, or across a block, comes back missing and draws initials.
                    val rows = runCatching {
                        T1App.supabase.postgrest.rpc("people", buildJsonObject {
                            put("p_ids", kotlinx.serialization.json.JsonArray(ids.map { kotlinx.serialization.json.JsonPrimitive(it) }))
                        }).decodeList<Row>()
                    }.getOrNull()
                    pending -= ids.toSet()
                    if (rows == null) continue   // offline: ask again next time it's drawn
                    ids.forEach { paths[it] = null }
                    rows.forEach { paths[it.userId] = it.avatarUrl }
                }
            } finally {
                flushing = false
            }
        }
    }

    /** Your own change, shown at once. */
    fun set(userId: String, path: String?) { paths[userId] = path }

    @Serializable
    private data class Result(@SerialName("avatar_url") val avatarUrl: String? = null, val previous: String? = null)

    /** Uploads to <user_id>/<random>.jpg, points the profile at it, then removes the old file. */
    suspend fun upload(jpeg: ByteArray) {
        val uid = T1App.supabase.auth.currentUserOrNull()?.id?.lowercase() ?: return
        val path = "$uid/${UUID.randomUUID().toString().lowercase()}.jpg"
        val bucket = T1App.supabase.storage.from("avatars")
        bucket.upload(path, jpeg) {
            upsert = true
            contentType = ContentType.Image.JPEG
        }
        val result = T1App.supabase.postgrest.rpc("avatar_set", buildJsonObject { put("p_path", path) }).decodeAs<Result>()
        set(uid, path)
        result.previous?.takeIf { it != path }?.let { old -> runCatching { bucket.delete(old) } }
    }

    suspend fun clear() {
        val uid = T1App.supabase.auth.currentUserOrNull()?.id?.lowercase() ?: return
        val result = T1App.supabase.postgrest.rpc("avatar_clear").decodeAs<Result>()
        set(uid, null)
        result.previous?.let { old -> runCatching { T1App.supabase.storage.from("avatars").delete(old) } }
    }
}

/** Centre square, 512 px, JPEG 80: well under the bucket's 1 MB limit. Honours the camera's EXIF rotation. */
fun avatarJpeg(bytes: ByteArray): ByteArray? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val shortSide = minOf(bounds.outWidth, bounds.outHeight)
    if (shortSide <= 0) return null
    var sample = 1
    while (shortSide / (sample * 2) >= 512) sample *= 2
    val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
        ?: return null
    val degrees = runCatching {
        when (ExifInterface(bytes.inputStream()).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> 0
        }
    }.getOrDefault(0)
    val side = minOf(decoded.width, decoded.height)
    val out = minOf(512, side)
    val matrix = Matrix().apply {
        postScale(out.toFloat() / side, out.toFloat() / side)
        postRotate(degrees.toFloat())
    }
    val square = Bitmap.createBitmap(decoded, (decoded.width - side) / 2, (decoded.height - side) / 2, side, side, matrix, true)
    return ByteArrayOutputStream().use { stream ->
        square.compress(Bitmap.CompressFormat.JPEG, 80, stream)
        stream.toByteArray()
    }
}

/** A square tile: the photo when the account has one, otherwise initials on its color. */
@Composable
fun Avatar(name: String, userId: String?, size: Int = 24) {
    LaunchedEffect(userId) { userId?.let { AvatarStore.want(it) } }
    val path = userId?.let { AvatarStore.path(it) }
    var failed by remember { mutableStateOf<String?>(null) }
    val fontSize = with(LocalDensity.current) { (size * 0.4f).dp.toSp() }
    Box(
        Modifier.size(size.dp).clipToBounds().background(AvatarStyle.color(userId, name)).clearAndSetSemantics {},
        contentAlignment = Alignment.Center,
    ) {
        Text(
            AvatarStyle.initials(name), color = T1.text, fontFamily = T1.mono, fontWeight = FontWeight.Medium,
            fontSize = fontSize, letterSpacing = with(LocalDensity.current) { 0.5.dp.toSp() }, maxLines = 1, softWrap = false,
        )
        if (path != null && failed != path) {
            AsyncImage(
                model = AvatarStore.url(path), contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.size(size.dp), onError = { failed = path },
            )
        }
    }
}
