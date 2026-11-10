package site.table1.events.ui.screens

import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import site.table1.events.data.JoinLink
import site.table1.events.data.Repo
import site.table1.events.insights.JoinCode
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.Notice
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled

/**
 * Join with the organizer's event code: typed, or Paste, which reads a code, a join link or the QR's link out of what
 * was copied ([JoinCode.parse]; contract/qr-sign-up-2026-10-23.md § Enter or paste a code). A long paste into the field
 * is read the same way.
 */
@Composable
fun JoinCodeRow(onJoined: (String) -> Unit) {
    val context = LocalContext.current
    val focus = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    val clipboard = remember { context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager }
    var code by remember { mutableStateOf("") }
    var qr by remember { mutableStateOf<JoinCode.Qr?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var canPaste by remember { mutableStateOf(clipboard.hasPrimaryClip()) }
    DisposableEffect(clipboard) {
        val listener = ClipboardManager.OnPrimaryClipChangedListener { canPaste = clipboard.hasPrimaryClip() }
        clipboard.addPrimaryClipChangedListener(listener)
        onDispose { clipboard.removePrimaryClipChangedListener(listener) }
    }

    fun join() {
        if (code.length != 4 || busy) return
        busy = true; error = null; focus.clearFocus()
        val link = qr?.takeIf { it.code == code }
        scope.launch {
            runCatching { if (link != null) Repo.joinByQr(JoinLink(link.code, link.secret)) else Repo.joinByCode(code, via = "code") }
                .onSuccess { code = ""; qr = null; onJoined(it.eventId) }
                .onFailure { it.rethrowIfCancelled(); error = it.message ?: "Couldn't join with that code." }
            busy = false
        }
    }

    fun take(found: JoinCode) {
        code = found.code
        qr = found as? JoinCode.Qr
    }

    /** What's in the field: a code typed in keeps to 4 letters and digits; anything longer (a pasted message or link)
     *  is read for its code. */
    fun typed(text: String) {
        error = null
        val plain = text.uppercase().filter { it in 'A'..'Z' || it in '0'..'9' }
        if (text.length <= 4) { code = plain; if (qr?.code != plain) qr = null; return }
        val found = JoinCode.parse(text)
        Telemetry.capture("join_code_pasted", mapOf("via" to "field", "found" to (found != null)))
        if (found != null) take(found) else { code = plain.take(4); if (text.length > 6) error = "That has no event code in it." }
    }

    fun paste() {
        val text = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
        val found = JoinCode.parse(text)
        Telemetry.capture("join_code_pasted", mapOf("via" to "paste", "found" to (found != null)))
        if (found == null) { error = "What you copied has no event code in it."; return }
        take(found)
        join()
    }

    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Row(Modifier.fillMaxWidth().background(T1.bg), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            Box(Modifier.weight(1f).height(50.dp).background(T1.surface).padding(horizontal = 16.dp), contentAlignment = Alignment.CenterStart) {
                if (code.isEmpty()) Text("EVENT CODE", color = T1.muted, fontFamily = T1.mono, fontSize = 16.sp, letterSpacing = 4.sp)
                BasicTextField(code, ::typed, Modifier.fillMaxWidth().semantics { contentDescription = "Event code" }, singleLine = true,
                    textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 16.sp, letterSpacing = 4.sp),
                    cursorBrush = SolidColor(T1.accent),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { join() }))
            }
            if (canPaste && code.isEmpty()) {
                Box(Modifier.height(50.dp).background(T1.surface).clickable(onClickLabel = "Paste an event code") { paste() }.padding(horizontal = 18.dp),
                    contentAlignment = Alignment.Center) { Label("Paste", color = T1.text) }
            }
            val ready = code.length == 4 && !busy
            Box(Modifier.height(50.dp).background(if (ready) T1.text else T1.disabled).clickable(enabled = ready) { join() }.padding(horizontal = 18.dp),
                contentAlignment = Alignment.Center) { Label(if (busy) "…" else "Join", color = T1.ink) }
        }
        error?.let { Notice(it, error = true) }
    }
}
