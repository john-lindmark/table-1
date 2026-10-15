package site.table1.events.util

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.tasks.await

data class Fix(val lat: Double, val lng: Double, val accuracyM: Int)

/** One foreground fix. Callers request ACCESS_FINE/COARSE_LOCATION first. */
@SuppressLint("MissingPermission")
suspend fun currentFix(context: Context): Fix? = runCatching {
    val client = LocationServices.getFusedLocationProviderClient(context)
    val location = client.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, CancellationTokenSource().token).await()
    location?.let { Fix(it.latitude, it.longitude, it.accuracy.toInt().coerceAtLeast(5)) }
}.getOrNull()

/** Google's system QR scanner: no camera permission, no custom camera UI. Null if cancelled. */
suspend fun scanQr(context: Context): String? = try {
    val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
    GmsBarcodeScanning.getClient(context, options).startScan().await().rawValue
} catch (e: Exception) {
    null
}

fun qrBitmap(text: String, size: Int = 720): ImageBitmap {
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.MARGIN to 1))
    val pixels = IntArray(size * size) { i ->
        if (matrix.get(i % size, i / size)) 0xFF171725.toInt() else 0xFFFFFFFF.toInt()
    }
    return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888).asImageBitmap()
}
