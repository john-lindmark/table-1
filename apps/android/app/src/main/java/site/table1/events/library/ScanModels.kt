package site.table1.events.library

import android.content.Context
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import kotlinx.coroutines.tasks.await
import site.table1.events.util.rethrowIfCancelled

/**
 * The scanner's Japanese, Chinese and Korean text models. They're Play services modules, not in the app: without
 * them every CJK frame fails ("Waiting for the text optional module to be downloaded"), and ML Kit's own request on
 * first use is the old Vision broadcast, which Play may leave for later. The manifest asks for them at install
 * (`ocr_japanese`, `ocr_chinese`, `ocr_korean`); this asks again, urgently, when the scanner opens on a phone that
 * doesn't have them (installs from before 2026-11-08, sideloads). Same as qrScannerReady.
 */
object ScanModels {
    /** Recognizers in ScanLanguage.READERS order (Japanese, Chinese, Korean). */
    fun recognizer(reader: Int): TextRecognizer = TextRecognition.getClient(
        when (reader) {
            0 -> JapaneseTextRecognizerOptions.Builder().build()
            1 -> ChineseTextRecognizerOptions.Builder().build()
            else -> KoreanTextRecognizerOptions.Builder().build()
        },
    )

    /**
     * Whether the CJK models are on the phone, asking Play services to install them if not: `ready` (they were),
     * `requested` (Play is installing them now), `no_play` (no or old Play services) or `failed`.
     */
    suspend fun ensure(context: Context): String {
        val apis = ScanLanguage.READERS.indices.map(::recognizer)
        return try {
            if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) != ConnectionResult.SUCCESS) return "no_play"
            val modules = ModuleInstall.getClient(context)
            if (modules.areModulesAvailable(*apis.toTypedArray()).await().areModulesAvailable()) return "ready"
            val request = ModuleInstallRequest.newBuilder().apply { apis.forEach { addApi(it) } }.build()
            if (modules.installModules(request).await().areModulesAlreadyInstalled()) "ready" else "requested"
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            "failed"
        } finally {
            apis.forEach { it.close() }
        }
    }
}
