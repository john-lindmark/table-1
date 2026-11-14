package site.table1.events.ui.screens

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.library.ListEntry

// The decklist read from a deck photo (contract/deck-photo-lists-2026-11-13.md): the data and the rules, the same as
// iOS DeckPhotoList and web deckPhotoList.ts, checked against testdata/deck-photo-lists/cases.json (DeckPhotoListTest).

/** One line of a photo's decklist. `cardId` null = a title the reader couldn't match to a card. */
@Serializable(with = DeckListEntrySerializer::class)
data class DeckListEntry(
    val cardId: String?,
    val name: String,
    val qty: Int,
    /** main | side | out */
    val board: String,
    val sure: Boolean = true,
    val read: String? = null,
) {
    /** As `deck_photo_list_save` takes it. */
    val json: JsonObject
        get() = buildJsonObject {
            cardId?.let { put("card_id", it) }
            put("name", name); put("qty", qty); put("board", board); put("sure", sure)
            if (!read.isNullOrEmpty()) put("read", read)
        }
}

/** The wire shape; anything missing reads as a sure main-deck line. */
@Serializable
private class DeckListEntryWire(
    @SerialName("card_id") val cardId: String? = null,
    val name: String? = null,
    val qty: Int? = null,
    val board: String? = null,
    val sure: Boolean? = null,
    val read: String? = null,
)

object DeckListEntrySerializer : KSerializer<DeckListEntry> {
    override val descriptor: SerialDescriptor = DeckListEntryWire.serializer().descriptor

    override fun deserialize(decoder: Decoder): DeckListEntry {
        val w = decoder.decodeSerializableValue(DeckListEntryWire.serializer())
        return DeckListEntry(w.cardId, w.name ?: "", w.qty ?: 1, if (w.board == "side" || w.board == "out") w.board else "main",
            w.sure ?: true, w.read)
    }

    override fun serialize(encoder: Encoder, value: DeckListEntry) = encoder.encodeSerializableValue(
        DeckListEntryWire.serializer(),
        DeckListEntryWire(value.cardId, value.name, value.qty, value.board, value.sure, value.read?.takeIf { it.isNotEmpty() }),
    )
}

/** A photo row's `list`: where its decklist stands. */
@Serializable
data class DeckListBrief(val status: String = "done", val cards: Int = 0, val check: Int = 0, val checked: Boolean = false)

@Serializable
data class DeckPhotoListData(
    @SerialName("photo_id") val photoId: String = "",
    @SerialName("event_id") val eventId: String? = null,
    val player: String? = null,
    val path: String? = null,
    val turns: Int? = null,
    val status: String = "none",
    val steps: List<String> = emptyList(),
    val entries: List<DeckListEntry> = emptyList(),
    val message: String? = null,
    val notes: String? = null,
    val pool: Pool? = null,
    val checked: Boolean? = null,
    val editable: Boolean? = null,
    val mine: Boolean? = null,
    @SerialName("reads_left") val readsLeft: Int? = null,
    val event: Event? = null,
) {
    @Serializable
    data class Pool(val kind: String? = null, val label: String? = null, val size: Int? = null)

    @Serializable
    data class Event(
        val name: String? = null,
        val format: String? = null,
        @SerialName("event_type") val eventType: String? = null,
        @SerialName("format_label") val formatLabel: String? = null,
    )

    val reading: Boolean get() = status == "queued" || status == "reading"
}

object DeckPhotoList {
    data class Counts(val main: Int = 0, val side: Int = 0, val out: Int = 0, val check: Int = 0)
    data class Card(val cardId: String, val name: String)
    data class DeckEntries(val entries: List<ListEntry>, val skipped: Int)

    private fun cards(n: Int) = "$n ${if (n == 1) "card" else "cards"}"

    /** A line someone should look at: no card, or the reader wasn't sure. Left-out lines never need it. */
    fun toCheck(e: DeckListEntry) = e.board != "out" && (e.cardId == null || !e.sure)

    /** The line under a photo. */
    fun row(brief: DeckListBrief?): String {
        val b = brief ?: return "Read decklist"
        if (b.status == "queued" || b.status == "reading") return "Reading the decklist…"
        if (b.status == "failed") return "Decklist · couldn't read · try again"
        if (b.cards <= 0) return "Decklist · no cards read"
        val text = "Decklist · ${cards(b.cards)}"
        if (b.checked) return "$text · checked"
        return if (b.check > 0) "$text · ${b.check} to check" else text
    }

    /** Cards the main deck should hold, when the event says. */
    fun target(eventType: String?, format: String?): Int? {
        val f = (format ?: "").lowercase()
        val t = (eventType ?: "").lowercase()
        if (t == "limited") return 40
        if (f == "commander" || f == "canadian_highlander" || f == "canlander") return 100
        if (t == "constructed") return 60
        return null
    }

    fun counts(entries: List<DeckListEntry>): Counts {
        var main = 0; var side = 0; var out = 0; var check = 0
        for (e in entries) {
            when (e.board) { "side" -> side += e.qty; "out" -> out += e.qty; else -> main += e.qty }
            if (toCheck(e)) check += 1
        }
        return Counts(main, side, out, check)
    }

    fun sizeLine(main: Int, target: Int?): String {
        val text = cards(main)
        if (target != null && main < target) return "$text · ${target - main} short of $target"
        if (target == 100 && main > 100) return "$text · ${main - 100} over 100"
        return text
    }

    private fun order(board: String) = when (board) { "side" -> 1; "out" -> 2; else -> 0 }
    private fun key(e: DeckListEntry) = "${e.cardId ?: ("?" + e.name.lowercase())}|${e.board}"

    /** The same card on the same board is one line (first place kept); main, then side, then out. */
    fun tidy(entries: List<DeckListEntry>): List<DeckListEntry> {
        val out = mutableListOf<DeckListEntry>()
        val at = HashMap<String, Int>()
        for (e in entries) {
            val i = at[key(e)]
            if (i == null) {
                at[key(e)] = out.size
                out += e
            } else {
                var line = out[i].copy(qty = minOf(99, out[i].qty + e.qty))
                if (!e.sure) {
                    line = line.copy(sure = false)
                    if (!e.read.isNullOrEmpty() && line.read.isNullOrEmpty()) line = line.copy(read = e.read)
                }
                out[i] = line
            }
        }
        return out.sortedBy { order(it.board) }   // stable: lines keep their place within a board
    }

    /** 0 removes the line; 99 at most. */
    fun setQty(entries: List<DeckListEntry>, i: Int, qty: Int): List<DeckListEntry> {
        if (i !in entries.indices) return entries
        return if (qty <= 0) entries.filterIndexed { at, _ -> at != i }
        else entries.mapIndexed { at, e -> if (at == i) e.copy(qty = minOf(99, qty)) else e }
    }

    fun move(entries: List<DeckListEntry>, i: Int, board: String): List<DeckListEntry> {
        if (i !in entries.indices) return entries
        return tidy(entries.mapIndexed { at, e -> if (at == i) e.copy(board = board) else e })
    }

    /** The player picked the card this line really is: sure, nothing left to check. */
    fun replace(entries: List<DeckListEntry>, i: Int, card: Card): List<DeckListEntry> {
        if (i !in entries.indices) return entries
        return tidy(entries.mapIndexed { at, e -> if (at == i) DeckListEntry(card.cardId, card.name, e.qty, e.board) else e })
    }

    fun confirm(entries: List<DeckListEntry>, i: Int): List<DeckListEntry> {
        if (i !in entries.indices || entries[i].cardId == null) return entries
        return entries.mapIndexed { at, e -> if (at == i) e.copy(sure = true, read = null) else e }
    }

    fun add(entries: List<DeckListEntry>, card: Card, board: String): List<DeckListEntry> =
        tidy(entries + DeckListEntry(card.cardId, card.name, 1, board))

    /** What a new deck takes: main and sideboard lines with a card; lines without one are left out and counted. */
    fun deckEntries(entries: List<DeckListEntry>): DeckEntries {
        val out = mutableListOf<ListEntry>()
        var skipped = 0
        for (e in entries) {
            if (e.board == "out") continue
            val id = e.cardId
            if (id == null) { skipped += 1; continue }
            val i = out.indexOfFirst { it.cardId == id && it.board == e.board }
            if (i >= 0) out[i] = ListEntry(id, e.board, out[i].qty + e.qty) else out += ListEntry(id, e.board, e.qty)
        }
        return DeckEntries(out, skipped)
    }

    fun deckName(event: String?, player: String?, mine: Boolean): String {
        var name = (event ?: "").trim()
        if (name.isEmpty()) name = "Deck photo"
        val p = (player ?: "").trim()
        if (!mine && p.isNotEmpty()) name = "$p · $name"
        return name.take(60).trim()
    }

    fun deckFormat(eventType: String?, format: String?): String {
        val f = (format ?: "").lowercase()
        if (f == "canadian_highlander") return "canlander"
        return if (f in setOf("standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander")) f else "other"
    }

    /** "2 lines without a card were left out." */
    fun skippedLine(skipped: Int) = "$skipped line${if (skipped == 1) "" else "s"} without a card ${if (skipped == 1) "was" else "were"} left out."
}
