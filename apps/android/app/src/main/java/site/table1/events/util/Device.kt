package site.table1.events.util

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
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

/** What Google's system QR scanner gave back. */
sealed interface QrScan {
    data class Read(val text: String) : QrScan
    data object Cancelled : QrScan
    /** Play services or its code scanner module isn't on this phone (yet). */
    data object Unavailable : QrScan
}

/**
 * Google's system QR scanner: no camera permission, no custom camera UI. It's only started once [qrScannerReady]
 * says it can open: on a phone whose Play services lacks the scanner, ML Kit's delegate activity throws
 * ActivityNotFoundException in its own onCreate, which no try here can catch, and the app crashes (bug #34).
 */
suspend fun scanQr(context: Context): QrScan {
    if (!qrScannerReady(context)) return QrScan.Unavailable
    return try {
        GmsBarcodeScanning.getClient(context, qrOptions).startScan().await().rawValue
            ?.let { QrScan.Read(it) } ?: QrScan.Cancelled
    } catch (e: Exception) {
        e.rethrowIfCancelled()
        QrScan.Cancelled
    }
}

private val qrOptions get() = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()

/**
 * Whether the scanner can open: Play services is there and up to date, and its code scanner module is installed.
 * A missing module is asked for once (Play installs it in the background; the manifest's ML Kit DEPENDENCIES asks
 * for it at install too), so a later tap works. Anything that fails reads as not ready.
 */
suspend fun qrScannerReady(context: Context): Boolean {
    return try {
        if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) != ConnectionResult.SUCCESS) {
            return false
        }
        val scanner = GmsBarcodeScanning.getClient(context, qrOptions)
        val modules = ModuleInstall.getClient(context)
        if (modules.areModulesAvailable(scanner).await().areModulesAvailable()) return true
        modules.installModules(ModuleInstallRequest.newBuilder().addApi(scanner).build()).await()
        modules.areModulesAvailable(scanner).await().areModulesAvailable()
    } catch (e: Exception) {
        e.rethrowIfCancelled()
        false
    }
}

fun qrBitmap(text: String, size: Int = 720): ImageBitmap {
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.MARGIN to 1))
    val pixels = IntArray(size * size) { i ->
        if (matrix.get(i % size, i / size)) 0xFF171725.toInt() else 0xFFFFFFFF.toInt()
    }
    return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888).asImageBitmap()
}
