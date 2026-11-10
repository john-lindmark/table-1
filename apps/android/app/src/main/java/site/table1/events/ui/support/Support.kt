package site.table1.events.ui.support

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.text.Normalizer

/*
 * Support (contract/support-2026-11-10.md): answers to common questions (assets/support/faq.json) and the user-facing
 * part of the Feature Guide (assets/support/guide.json, scrubbed by tools/support/make_guide.py), from the folder the
 * app bundles from marketing/bundle (the same files the web and iOS read). Search is one rule on every platform,
 * checked by SupportTest against testdata/support-search/cases.json.
 */

@Serializable
data class SupportTopic(val key: String, val title: String)

@Serializable
data class SupportFaq(val id: String, val topic: String, val q: String, val a: String, val keywords: List<String> = emptyList(), val guide: String? = null)

@Serializable
data class GuideSection(val id: String, val title: String)

/** A guide entry: its section, the subheading it sits under, its lead (the bold words it opens on) and its text. */
@Serializable
data class GuideEntry(val id: String, val s: String, val h: String? = null, val t: String? = null, val x: String)

@Serializable
data class SupportContact(val discord: String, val email: String)

@Serializable
data class FaqFile(val updated: String, val contact: SupportContact, val topics: List<SupportTopic>, val faqs: List<SupportFaq>)

@Serializable
data class GuideFile(val sections: List<GuideSection>, val entries: List<GuideEntry>)

sealed class SupportDoc {
    abstract val id: String
    abstract val kind: String
    data class Faq(val faq: SupportFaq) : SupportDoc() { override val id get() = faq.id; override val kind get() = "faq" }
    data class Guide(val entry: GuideEntry) : SupportDoc() { override val id get() = entry.id; override val kind get() = "guide" }
}

data class SupportHit(val doc: SupportDoc, val score: Int)

/** The FAQ and guide, indexed for search. */
class SupportContent(val faq: FaqFile, val guide: GuideFile) {
    private class Indexed(val doc: SupportDoc, val primary: List<String>, val fields: List<Pair<Int, List<String>>>)

    fun topicTitle(key: String): String = faq.topics.firstOrNull { it.key == key }?.title ?: key
    fun sectionTitle(id: String): String = guide.sections.firstOrNull { it.id == id }?.title ?: id
    fun faqsOf(topic: String): List<SupportFaq> = faq.faqs.filter { it.topic == topic }

    /** A section's entries by subheading, in order (entries before any subheading under ""). */
    fun groups(section: String): List<Pair<String, List<GuideEntry>>> {
        val out = mutableListOf<Pair<String, MutableList<GuideEntry>>>()
        for (e in guide.entries) {
            if (e.s != section) continue
            val h = e.h ?: ""
            val last = out.lastOrNull()
            if (last != null && last.first == h) last.second += e else out += h to mutableListOf(e)
        }
        return out
    }

    /** The question, or the entry's lead (else its opening words). */
    fun title(doc: SupportDoc): String = when (doc) {
        is SupportDoc.Faq -> doc.faq.q
        is SupportDoc.Guide -> doc.entry.t ?: Support.clip(doc.entry.x, 90)
    }

    fun detail(doc: SupportDoc): String = when (doc) {
        is SupportDoc.Faq -> "FAQ · ${topicTitle(doc.faq.topic)}"
        is SupportDoc.Guide -> "Guide · ${sectionTitle(doc.entry.s)}"
    }

    /** Every FAQ in file order, then every guide entry, with their fields' words and weights. */
    private val corpus: List<Indexed> by lazy {
        val w = Support::words
        faq.faqs.map { f ->
            Indexed(SupportDoc.Faq(f), w(f.q), listOf(4 to w(f.q), 3 to w(f.keywords.joinToString(" ")), 2 to w(topicTitle(f.topic)), 1 to w(f.a)))
        } + guide.entries.map { e ->
            Indexed(SupportDoc.Guide(e), w(e.t ?: e.h ?: ""), listOf(3 to w(e.t ?: ""), 2 to w(e.h ?: ""), 2 to w(sectionTitle(e.s)), 1 to w(e.x)))
        }
    }

    /**
     * Best first: every query word must start a word in some field (FAQ question 4, keywords 3, topic 2, answer 1;
     * guide lead 3, subheading 2, section 2, text 1); the score is twice the best weights' sum, +6 when the whole query
     * starts the question or lead in order, +1 for an FAQ. With nothing matching every word, the docs that match the
     * most words, marked partial.
     */
    fun search(q: String): Pair<List<SupportHit>, Boolean> {
        if (q.trim().length < 2) return emptyList<SupportHit>() to false
        val qw = Support.queryWords(q)
        if (qw.isEmpty()) return emptyList<SupportHit>() to false
        val all = Support.words(q)
        data class Scored(val matched: Int, val score: Int, val order: Int, val doc: SupportDoc)
        val scored = mutableListOf<Scored>()
        corpus.forEachIndexed { order, d ->
            var matched = 0
            var sum = 0
            for (w in qw) {
                var b = 0
                for ((weight, field) in d.fields) if (weight > b && field.any { Support.hit(w, it) }) b = weight
                if (b > 0) { matched++; sum += b }
            }
            if (matched == 0) return@forEachIndexed
            val score = 2 * sum + (if (Support.phrase(all, d.primary)) 6 else 0) + (if (d.doc is SupportDoc.Faq) 1 else 0)
            scored += Scored(matched, score, order, d.doc)
        }
        if (scored.isEmpty()) return emptyList<SupportHit>() to false
        var full = scored.filter { it.matched == qw.size }
        var partial = false
        if (full.isEmpty()) {
            if (qw.size < 2) return emptyList<SupportHit>() to false
            val top = scored.maxOf { it.matched }
            full = scored.filter { it.matched == top }
            partial = true
        }
        val sorted = full.sortedWith(compareByDescending<Scored> { it.score }.thenBy { if (it.doc is SupportDoc.Faq) 0 else 1 }.thenBy { it.order })
        return sorted.take(Support.LIMIT).map { SupportHit(it.doc, it.score) } to partial
    }
}

object Support {
    val STOP = setOf("a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "my", "me", "i", "is", "it",
        "do", "does", "how", "can", "what", "why", "when", "where", "you", "your", "are", "be", "at", "by", "from", "this",
        "that", "there", "as", "if", "not")
    const val LIMIT = 50

    private val json = Json { ignoreUnknownKeys = true }
    @Volatile private var cached: SupportContent? = null

    fun parse(faq: String, guide: String): SupportContent =
        SupportContent(json.decodeFromString(faq), json.decodeFromString(guide))

    /** The bundled files, read once; null when they're missing or don't decode. */
    fun load(context: Context): SupportContent? = cached ?: runCatching {
        fun read(name: String) = context.assets.open("support/$name").use { it.readBytes().toString(Charsets.UTF_8) }
        parse(read("faq.json"), read("guide.json"))
    }.getOrNull()?.also { cached = it }

    /** Lowercase, accents off, apostrophes dropped (don't → dont); anything else that isn't a letter or digit splits. */
    fun words(text: String): List<String> {
        val s = Normalizer.normalize(text, Normalizer.Form.NFKD)
        val out = mutableListOf<String>()
        val cur = StringBuilder()
        for (ch in s) {
            if (ch in '̀'..'ͯ' || ch == '\'' || ch == '’') continue
            val c = ch.lowercaseChar()
            if (c in 'a'..'z' || c in '0'..'9') cur.append(c)
            else if (cur.isNotEmpty()) { out += cur.toString(); cur.clear() }
        }
        if (cur.isNotEmpty()) out += cur.toString()
        return out
    }

    /** The words a search looks for: stop words left out (unless that leaves none), each once. */
    fun queryWords(q: String): List<String> {
        val all = words(q)
        val kept = all.filter { it !in STOP }
        return (kept.ifEmpty { all }).distinct()
    }

    fun hit(q: String, w: String): Boolean = w.startsWith(q) || (q.length >= 4 && q.endsWith("s") && w.startsWith(q.dropLast(1)))

    fun phrase(all: List<String>, primary: List<String>): Boolean {
        if (all.size < 2) return false
        for (i in 0..primary.size - all.size) if (all.indices.all { primary[i + it].startsWith(all[it]) }) return true
        return false
    }

    fun clip(s: String, n: Int): String {
        if (s.length <= n) return s
        val cut = s.take(n - 1)
        val space = cut.lastIndexOf(' ')
        return (if (space > 0) cut.substring(0, space) else cut) + "…"
    }
}
