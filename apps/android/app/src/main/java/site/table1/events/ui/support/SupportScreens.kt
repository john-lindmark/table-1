package site.table1.events.ui.support

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import site.table1.events.library.IconGlyph
import site.table1.events.library.T1Icon
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Support (contract/support-2026-11-10.md; iOS UI/Support.swift, web screens/Support.tsx): Account → Support. The home
   is a search box over the FAQ and the guide, then the FAQ topics, the guide and where to ask; a topic lists its
   questions, a question opens its answer, a guide section reads whole, scrolled to the entry a search found. */

/** Navigation out of the Support screens (AppRoot's routes). */
class SupportNav(
    val back: () -> Unit,
    val topic: (String) -> Unit,
    val guides: () -> Unit,
    val faq: (id: String, from: String) -> Unit,
    val guide: (section: String, entry: String?, from: String) -> Unit,
)

/** Account → Support. */
fun LazyListScope.supportAccountRow(onOpen: () -> Unit) {
    item { ListRow("Support", "Questions and the guide", onClick = onOpen) }
}

@Composable
private fun rememberSupport(): SupportContent? {
    val context = LocalContext.current
    return remember { Support.load(context) }
}

@Composable
fun SupportScreen(nav: SupportNav) {
    val content = rememberSupport()
    var query by rememberSaveable { mutableStateOf("") }
    val searching = query.trim().length >= 2
    val found = remember(query, content) { content?.search(query) ?: (emptyList<SupportHit>() to false) }
    // One event once typing settles: how many words and results, never the words themselves.
    LaunchedEffect(query) {
        if (!searching) return@LaunchedEffect
        delay(1_200)
        Telemetry.capture("support_searched", mapOf("words" to query.trim().split(Regex("\\s+")).size, "results" to found.first.size, "partial" to found.second))
    }
    T1Screen {
        Bar("Support", onBack = nav.back)
        SupportSearchField(query) { query = it }
        LazyColumn(Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (content == null) {
                item { Notice("This isn't available.") }
                return@LazyColumn
            }
            if (searching) {
                val (hits, partial) = found
                if (hits.isEmpty()) item { Notice("Nothing matches that. Try fewer or other words, or ask below.") }
                else item { Section("${if (partial) "Closest matches" else "Results"} · ${hits.size}") }
                items(hits.withIndex().toList(), key = { "${it.value.doc.kind}:${it.value.doc.id}" }) { (i, h) ->
                    SupportRow(content.title(h.doc), content.detail(h.doc)) {
                        Telemetry.capture("support_result_opened", mapOf("kind" to h.doc.kind, "rank" to i))
                        when (val d = h.doc) {
                            is SupportDoc.Faq -> nav.faq(d.faq.id, "search")
                            is SupportDoc.Guide -> nav.guide(d.entry.s, d.entry.id, "search")
                        }
                    }
                }
            } else {
                item { Section("Questions") }
                items(content.faq.topics, key = { it.key }) { t ->
                    ListRow(t.title, onClick = { nav.topic(t.key) }) {
                        Text("${content.faqsOf(t.key).size}", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
                    }
                }
                item { Section("Guide") }
                item { ListRow("Everything Table 1 does", "${content.guide.sections.size} sections", onClick = nav.guides) }
            }
            contact(content.faq.contact)
        }
    }
}

@Composable
private fun SupportSearchField(value: String, onChange: (String) -> Unit) {
    // The whole box is the decoration: a tap anywhere in it focuses the field.
    BasicTextField(
        value = value, onValueChange = onChange, singleLine = true,
        textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 15.sp),
        cursorBrush = SolidColor(T1.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        modifier = Modifier.fillMaxWidth(),
        decorationBox = { inner ->
            Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                IconGlyph(T1Icon.Search, color = T1.muted)
                Box(Modifier.weight(1f)) {
                    if (value.isEmpty()) Text("Search questions and the guide", color = T1.muted, fontFamily = T1.mono, fontSize = 15.sp)
                    inner()
                }
                if (value.isNotEmpty()) Label("Clear", Modifier.clickable { onChange("") }, color = T1.text)
            }
        },
    )
}

/** A row whose title may take two lines (questions, guide excerpts). */
@Composable
private fun SupportRow(title: String, detail: String, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().background(T1.surface).clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 2)
        Label(detail)
    }
}

private fun LazyListScope.contact(c: SupportContact) {
    item { Section("Still stuck") }
    item {
        val context = LocalContext.current
        ListRow("Ask in the Table 1 Discord", "discord.gg", onClick = {
            Telemetry.capture("support_contact", mapOf("how" to "discord"))
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(c.discord))) }
        }) { Label("Open", color = T1.text) }
    }
    item {
        val context = LocalContext.current
        ListRow("Account and privacy", c.email, onClick = {
            Telemetry.capture("support_contact", mapOf("how" to "email"))
            runCatching { context.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:${c.email}"))) }
        }) { Label("Email", color = T1.text) }
    }
}

@Composable
fun SupportGuidesScreen(nav: SupportNav) {
    val content = rememberSupport()
    T1Screen {
        Bar("Guide", onBack = nav.back)
        LazyColumn(Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            items(content?.guide?.sections ?: emptyList(), key = { it.id }) { s ->
                ListRow(s.title, onClick = { nav.guide(s.id, null, "index") })
            }
        }
    }
}

@Composable
fun SupportTopicScreen(topic: String, nav: SupportNav) {
    val content = rememberSupport()
    T1Screen {
        Bar(content?.topicTitle(topic) ?: "Support", onBack = nav.back)
        LazyColumn(Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            val faqs = content?.faqsOf(topic) ?: emptyList()
            if (faqs.isEmpty()) item { Notice("This isn't available.") }
            items(faqs, key = { it.id }) { f -> SupportRow(f.q, content!!.topicTitle(f.topic)) { nav.faq(f.id, "topic") } }
        }
    }
}

@Composable
fun SupportFaqScreen(id: String, from: String, nav: SupportNav) {
    val content = rememberSupport()
    val faq = content?.faq?.faqs?.firstOrNull { it.id == id }
    LaunchedEffect(id) { if (faq != null) Telemetry.capture("support_opened", mapOf("screen" to "faq", "id" to id, "from" to from)) }
    T1Screen {
        Bar(faq?.let { content.topicTitle(it.topic) } ?: "Support", onBack = nav.back)
        LazyColumn(Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (faq == null || content == null) {
                item { Notice("This isn't available.") }
                return@LazyColumn
            }
            item {
                SelectionContainer {
                    Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text(faq.q, color = T1.text, fontFamily = T1.mono, fontSize = 18.sp, lineHeight = 26.sp)
                        for (p in faq.a.split("\n\n")) {
                            Text(p, color = T1.text.copy(alpha = 0.9f), fontFamily = T1.mono, fontSize = 14.sp, lineHeight = 22.sp)
                        }
                    }
                }
            }
            faq.guide?.let { g -> item { ListRow(content.sectionTitle(g), "In the guide", onClick = { nav.guide(g, null, "faq") }) } }
            contact(content.faq.contact)
        }
    }
}

@Composable
fun SupportGuideScreen(section: String, entry: String?, from: String, nav: SupportNav) {
    val content = rememberSupport()
    val groups = remember(content, section) { content?.groups(section) ?: emptyList() }
    // Rows in order: a subheading, then its entries; the entry a search found is scrolled to.
    val rows = remember(groups) { groups.flatMap { (h, es) -> (if (h.isEmpty()) emptyList() else listOf<Any>(h)) + es } }
    val state = rememberLazyListState()
    LaunchedEffect(section, entry) {
        Telemetry.capture("support_opened", mapOf("screen" to "guide", "id" to section, "from" to from))
        val i = rows.indexOfFirst { it is GuideEntry && it.id == entry }
        if (i > 0) state.scrollToItem((i - 1).coerceAtLeast(0))
    }
    T1Screen {
        Bar(content?.sectionTitle(section) ?: "Support", "Guide", onBack = nav.back)
        LazyColumn(Modifier.fillMaxWidth().weight(1f), state = state, verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (rows.isEmpty()) item { Notice("This isn't available.") }
            items(rows.size) { i ->
                when (val r = rows[i]) {
                    is String -> Section(r)
                    is GuideEntry -> GuideEntryRow(r, r.id == entry)
                }
            }
        }
    }
}

@Composable
private fun GuideEntryRow(e: GuideEntry, picked: Boolean) {
    val text = buildAnnotatedString {
        e.t?.let { t ->
            val sep = if (t.last() in ".?!" || e.x.firstOrNull() in listOf('(', ':')) " " else ": "
            withStyle(SpanStyle(color = T1.text)) { append(t + sep) }
        }
        withStyle(SpanStyle(color = T1.text.copy(alpha = 0.85f))) { append(e.x) }
    }
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).background(T1.surface)) {
        if (picked) Box(Modifier.width(1.dp).fillMaxHeight().background(T1.accent))
        SelectionContainer(Modifier.weight(1f)) {
            Text(text, fontFamily = T1.mono, fontSize = 14.sp, lineHeight = 22.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp))
        }
    }
}
