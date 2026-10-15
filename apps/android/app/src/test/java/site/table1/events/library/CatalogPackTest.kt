package site.table1.events.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Base64

// Same cases as table-1-events-web/src/lib/catalog.test.ts.

/** Header, three cards (sorted by name_norm) and four printings, in pack format 1. */
private val PACK = listOf(
    "#t1catalog\t1\tv1-test\t3\t4",
    "O\t0\tae92942b-919c-4ea9-b693-85fcef765d5a\tFire // Ice\tfire ice\tInstant // Instant\t{1}{R} // {1}{U}\t4\tRU\tFire // Ice",
    "O\t1\t4457ed35-7c10-48c8-9776-456485fdf070\tLightning Bolt\tlightning bolt\tInstant\t{R}\t1\tR\t",
    "O\t2\t11111111-1111-1111-1111-111111111111\tLightning Bolt Token\tlightning bolt token\tToken Creature — Elemental\t\t0\tR\t",
    "P\t04cb4e4e-8275-4132-8f1a-84b486725400\t0\tf06\t12a\ten\tr\tf\t2006-01-01\t1783943569\t1\t",
    "P\tf29ba16f-c8fb-42fe-aabf-87089cb214a7\t1\t2x2\t117\ten\tu\tfn\t2022-07-08\t1783930000\t1\t",
    "P\t310de1ef-f1b6-4b61-9d6c-6b70382a7f95\t1\t4bb\t208\tes\tc\tn\t1995-04-01\t\t1\tRelámpago",
    "P\t22222222-2222-2222-2222-222222222222\t2\ttfoo\t1\ten\tc\tn\t2020-01-01\t\t0\t",
    "X\tfuture line type is ignored",
    "",
).joinToString("\n")

/** PACK gzipped by Python's gzip module (with a file name in the header). */
private const val PACK_GZ = "H4sICAAAAAAC/3BhY2sudHN2AG2SXWocMQzHn7WnGOiziO3x52tDC4FCy9JAX22PPBk6mQm73tISFnqIXqBn6U16ksq7m1BChDGybP8k/e03VeZY47yOIOGbxEr7Cj3ozUcQECmooFXCIENGTTFgsqFHb0qm4qwZTIT30466q6vuJhOU5k/s3Cz7Gpd6ip9deJTHx+2xRZp3ewQN29v/b3NKCVobR0Nv0GUpUPvsMThnURurOe1QhBPwYRrv6jItY/d2nSvMz8vUls8Jt0cGboG5CuTF8JXpyV5wu8/rV1pe0Lt6Cp62uusdxXrgBv7+/NW9m+meFpYSWDnO+gmEzkmTJvTKGdSyV+iLjOh10t46ZbQQfLYIC1JFYOwOCighLArJA6TzfdC9sYEbYWBRIUVpC2ZfEmpVCGNMBb0TPuSkpI6OT6rvrV/XgAcoCxOVQuFQ+DOxF2xnYi/FQJIKFplY5GQlhsFmtMmJ3qvoSjDtVVJiigfaQ4YFZAgGhW4lNoVp/vP7/iGOKwPVxfCV6cn4OWpZV77KFTYeFyguLbMemy9QDidZ52mhrv544D+176ZxWXc0bP4BnNHEvLICAAA="

private class Parsed(text: String) {
    val oracles = mutableListOf<PackOracle>()
    val printings = mutableListOf<PackPrinting>()
    val header = CatalogPack.parse(text, { oracles.add(it) }, { printings.add(it) })

    fun count(idx: Int) = printings.count { it.oracleIdx == idx }

    fun names(q: String): List<String> =
        CatalogPack.rank(oracles.map { CatalogPack.SearchCandidate(it.idx, it.nameNorm, it.typeLine, count(it.idx)) }, q)
            .map { i -> oracles.first { it.idx == i }.name }
}

class CardNameTest {
    @Test fun matchesCardNameNorm() {
        listOf(
            "Æther Vial" to "aether vial",
            "Lim-Dûl the Necromancer" to "lim dul the necromancer",
            "Urza's Saga" to "urzas saga",
            "Fire // Ice" to "fire ice",
            "  Jötun   Grunt " to "jotun grunt",
        ).forEach { (input, out) -> assertEquals(input, out, CardName.norm(input)) }
    }

    /** Russian printed names (pack N lines) keep their letters; й and ё lose their marks like Latin accents. */
    @Test fun keepsCyrillic() {
        assertEquals("азор законотворец", CardName.norm("Азор, Законотворец"))
        assertEquals("легендарныи еж", CardName.norm("Легендарный — Ёж"))
    }

    /**
     * Japanese, Chinese and Korean printed names keep their characters, with nothing between them: "、", "・" and
     * Korean word spaces don't count; half-width kana and split dakuten come back as one full-width character.
     */
    @Test fun keepsCjk() {
        assertEquals("死者の災厄ケイヤ", CardName.norm("死者の災厄、ケイヤ"))
        assertEquals("ジェイスベレレン", CardName.norm("ジェイス・ベレレン"))
        assertEquals("ガイア", CardName.norm("ｶﾞｲｱ"))
        assertEquals("불꽃그림자소환술", CardName.norm("불꽃그림자 소환술"))
        assertEquals("暴行大师 3bb", CardName.norm("暴行大师 3BB"))
        assertEquals("a i m ボット", CardName.norm("A.I.M.ボット"))
        assertEquals("耕作", CardName.norm("耕（こう）作（さく）"))
        assertEquals("沼", CardName.norm("沼（ぬま）"))
    }
}

class CatalogPackTest {
    @Test fun readsCardsAndPrintings() {
        val c = Parsed(PACK)
        assertEquals(PackHeader("v1-test", 3, 4), c.header)
        assertEquals(3, c.oracles.size)
        assertEquals(4, c.printings.size)
        assertEquals("Lightning Bolt", c.oracles[1].name)
        assertEquals("Fire // Ice", c.oracles[0].faceNames)
        assertEquals(4.0, c.oracles[0].cmc, 0.0)
        // Printings of card 1 start at position 1 and there are two of them, newest first.
        assertEquals(1, c.printings.indexOfFirst { it.oracleIdx == 1 })
        assertEquals(2, c.count(1))
        assertEquals("Relámpago", c.printings[2].printedName)
        assertEquals("f29ba16f-c8fb-42fe-aabf-87089cb214a7", c.printings[1].cardId)
        assertEquals("fn", c.printings[1].finishes)
        assertEquals(0, c.printings[3].imageFaces)
    }

    @Test fun readsPrintedNames() {
        val pack = PACK.replace("X\tfuture", "N\t1\tde\tBlitzschlag\nN\t9\tde\tout of range\nX\tfuture")
        val names = mutableListOf<PackName>()
        CatalogPack.parse(pack, {}, {}, { names.add(it) })
        assertEquals(listOf(PackName(1, "de", "Blitzschlag")), names)
    }

    @Test fun rejectsAnUnknownFormat() {
        assertThrows(CatalogFormatException::class.java) { CatalogPack.parse("#t1catalog\t2\tv\t0\t0", {}, {}) }
    }

    @Test fun gunzipsThePack() {
        val raw = String(CatalogPack.gunzip(Base64.getDecoder().decode(PACK_GZ)), Charsets.UTF_8)
        assertEquals(PACK, raw)
        assertEquals(4, Parsed(raw).printings.size)
    }

    @Test fun rejectsDamagedGzip() {
        assertThrows(CatalogFormatException::class.java) { CatalogPack.gunzip(PACK.toByteArray()) }
    }

    @Test fun buildsScryfallImageUrls() {
        assertEquals(
            "https://cards.scryfall.io/normal/front/f/2/f29ba16f-c8fb-42fe-aabf-87089cb214a7.jpg?1783930000",
            CatalogPack.imageUrl("f29ba16f-c8fb-42fe-aabf-87089cb214a7", "1783930000"),
        )
    }
}

class CatalogSearchTest {
    private val c = Parsed(PACK)

    @Test fun exactNameFirst() = assertEquals(listOf("Lightning Bolt", "Lightning Bolt Token"), c.names("lightning bolt"))

    @Test fun prefixFirstTokensLast() = assertEquals(listOf("Lightning Bolt", "Lightning Bolt Token"), c.names("light"))

    @Test fun wordInsideNameIgnoringAccentsAndPunctuation() {
        assertEquals(listOf("Lightning Bolt", "Lightning Bolt Token"), c.names("bolt"))
        assertEquals(listOf("Fire // Ice"), c.names("ice"))
    }

    @Test fun needsTwoCharacters() = assertEquals(emptyList<String>(), c.names("l"))
}

class CatalogPackFieldsTest {
    /** Legality code (O field 10) and the original-printing flag (P field 12); older packs leave both empty. */
    @Test fun readsLegalityAndOriginal() {
        val pack = listOf(
            "#t1catalog\t1\tv1-test\t2\t2",
            "O\t0\t5089ec1a-f881-4d55-af14-5d996171203b\tBlack Lotus\tblack lotus\tArtifact\t{0}\t0\t\t\t---BR-B-\t7",
            "O\t1\t4457ed35-7c10-48c8-9776-456485fdf070\tLightning Bolt\tlightning bolt\tInstant\t{R}\t1\tR\t",
            "P\tbd8fa327-dd41-4737-8f19-2cf5eb1f7cdd\t0\tlea\t232\ten\tr\tn\t1993-08-05\t1\t1\t\t1",
            "P\tf29ba16f-c8fb-42fe-aabf-87089cb214a7\t1\t2x2\t117\ten\tu\tfn\t2022-07-08\t1\t1\t",
        ).joinToString("\n")
        val o = mutableListOf<PackOracle>()
        val p = mutableListOf<PackPrinting>()
        CatalogPack.parse(pack, { o += it }, { p += it })
        assertEquals(listOf("---BR-B-", ""), o.map { it.legal })
        assertEquals(listOf(true, false), p.map { it.original })
        val lotus = CatalogOracle(0, "", "Black Lotus", "", "", "", 1, o[0].legal)
        assertEquals("restricted", lotus.legality("vintage"))
        assertEquals("banned", lotus.legality("legacy"))
        assertEquals("not_legal", lotus.legality("modern"))
        assertEquals(null, lotus.legality("other"))
        assertEquals("legal", lotus.legality("canlander"))
        assertEquals(listOf(7, 0), o.map { it.points })
    }
}
