package site.table1.events.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.sp

// Table 1 design language: hard rectangles, 1px hairlines, monospace, one teal accent
// that only ever means "this is the result".
object T1 {
    val bg = Color(0xFF171725)
    val surface = Color(0xFF282839)
    val surfaceHover = Color(0xFF33334A)
    val text = Color(0xFFFFFFFF)
    val muted = Color(0xFFC4C4CA)
    val disabled = Color(0xFF545461)
    val ink = Color(0xFF171725)
    val accent = Color(0xFF00FFD9)
    val danger = Color(0xFFFF6B6B)
    val warning = Color(0xFFFBBF24)
    /** Library Error (pink): the tracker's round clock in overtime and a lost total. */
    val error = Color(0xFFF2A3E5)
    val mono = FontFamily.Monospace
}

@Composable
fun Table1Theme(content: @Composable () -> Unit) {
    val base = TextStyle(fontFamily = T1.mono, color = T1.text)
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = T1.accent,
            onPrimary = T1.ink,
            background = T1.bg,
            onBackground = T1.text,
            surface = T1.surface,
            onSurface = T1.text,
            error = T1.danger,
        ),
        typography = Typography(
            bodyLarge = base.copy(fontSize = 15.sp),
            bodyMedium = base.copy(fontSize = 13.sp),
            labelSmall = base.copy(fontSize = 11.sp, letterSpacing = 1.sp),
            titleMedium = base.copy(fontSize = 15.sp),
        ),
        content = content,
    )
}
