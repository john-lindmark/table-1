package site.table1.events.widgets

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/*
 * The card icon widget's list and pick (contract/icon-widget-2026-11-06.md) against testdata/icon-widget/cases.json,
 * written by the Python reference there; iOS IconCardsTests reads the same file.
 */
class IconCardsTest {
    @Serializable data class Add(val name: String, val cards: List<IconCard>, val card: IconCard, val want: List<String>)
    @Serializable data class Remove(val name: String, val cards: List<IconCard>, val id: String, val want: List<String>)
    @Serializable data class Shown(val name: String, val cards: List<IconCard>, val chosen: String? = null, val want: String? = null)
    @Serializable data class Logo(val width: Float, val want: Float)
    @Serializable data class Cases(val limit: Int, val add: List<Add>, val remove: List<Remove>, val shown: List<Shown>, val logo: List<Logo>)

    private val dir = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/icon-widget") }.first { it.isDirectory }
    private val cases = Json { ignoreUnknownKeys = true }.decodeFromString<Cases>(File(dir, "cases.json").readText())

    @Test fun limit() = assertEquals(cases.limit, IconCards.LIMIT)

    @Test fun add() = cases.add.forEach { assertEquals(it.name, it.want, IconCards.add(it.cards, it.card).map(IconCard::id)) }

    @Test fun remove() = cases.remove.forEach { assertEquals(it.name, it.want, IconCards.remove(it.cards, it.id).map(IconCard::id)) }

    @Test fun shown() = cases.shown.forEach { assertEquals(it.name, it.want, IconCards.shown(it.cards, it.chosen)?.id) }

    @Test fun logoMatchesTheAppIcon() = cases.logo.forEach { assertEquals("${it.width}", it.want, IconCards.logoWidth(it.width), 0f) }
}
