package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import site.table1.events.insights.DeckInsightAnswer
import site.table1.events.insights.InsightsStore
import site.table1.events.insights.deckInsight
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/**
 * A deck's archetype on the deck's own screen (contract/insights-2026-10-24.md § A deck's archetype): its name, how
 * similar the deck is to the archetype's nearest list, 30-day win rate and change on last week (opens the archetype in
 * Insights), then its best and worst matchups; nothing for a brew. Same as web and iOS DeckMetaRows.
 */
@Composable
fun DeckMetaRows(listId: String, onOpen: (format: String, archetype: Int) -> Unit) {
    var answer by remember(listId) { mutableStateOf<DeckInsightAnswer?>(null) }
    LaunchedEffect(listId) {
        val r = InsightsStore.deckInsight(listId) ?: return@LaunchedEffect
        answer = r
        if (r.a != null && r.a != 0) Telemetry.capture("deck_insight_shown", mapOf("format" to r.format, "archetype" to r.a))
    }
    val r = answer ?: return
    val d = deckInsight(r)
    val a = r.a
    if (d.title == null || a == null) {
        d.note?.let { ListRow("In the meta", it) }
        return
    }
    val open = {
        Telemetry.capture("deck_insight_opened", mapOf("format" to r.format, "archetype" to a))
        onOpen(r.format, a)
    }
    // Similarity on a line of its own, so a phone still shows the change on last week.
    LinesRow(d.title, listOfNotNull(d.similar, listOfNotNull(d.win ?: "Too few matches for a win rate", d.change).joinToString(" · ")), open, value = "Insights")
    if (d.good.isNotEmpty()) LinesRow("Good against", d.good, open)
    if (d.bad.isNotEmpty()) LinesRow("Bad against", d.bad, open)
}

/** ListRow with one matchup (or fact) a line, so a phone shows them whole; `value` sits on the right like ListRow's. */
@Composable
private fun LinesRow(title: String, lines: List<String>, onClick: () -> Unit, value: String? = null) {
    Row(Modifier.fillMaxWidth().background(T1.surface).clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            lines.forEach { Label(it) }
        }
        value?.let { Text(it, color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, modifier = Modifier.padding(start = 12.dp)) }
    }
}
