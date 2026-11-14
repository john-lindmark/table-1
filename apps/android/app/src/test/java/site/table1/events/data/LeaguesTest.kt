package site.table1.events.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.util.Locale

/**
 * Finding events, leagues and format boards (contract/public-events-leagues-2026-11-13.md) on
 * testdata/leagues/cases.json, the file iOS LeaguesTests and the web's leagues.test.ts read, and the server's shapes
 * decoded from the stand-in fixture the Debug screens draw (src/debug/assets/leagues-demo.json).
 */
class LeaguesTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "testdata/leagues").isDirectory }
    private val all = Json.parseToJsonElement(File(root, "testdata/leagues/cases.json").readText()).jsonObject

    private fun cases(name: String) = all[name]!!.jsonArray.map { it.jsonObject }
    private fun str(e: JsonElement?) = e?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull
    private fun int(e: JsonElement?) = e?.takeIf { it !is JsonNull }?.jsonPrimitive?.intOrNull
    private fun want(o: JsonObject) = str(o["want"])

    @Test fun formatKeys() {
        assertEquals(all["format_keys"]!!.jsonArray.map { it.jsonObject["key"]!!.jsonPrimitive.content to it.jsonObject["label"]!!.jsonPrimitive.content },
            Leagues.formatKeys)
        assertEquals("Canadian Highlander", Leagues.label("canadian_highlander"))
        assertEquals("Other", Leagues.label("nope"))
    }

    @Test fun presets() {
        val p = all["presets"]!!.jsonObject
        assertEquals(json.decodeFromJsonElement<PointsRule>(p["places"]!!), Leagues.places)
        assertEquals(json.decodeFromJsonElement<PointsRule>(p["match_wins"]!!), Leagues.matchWins)
        assertEquals("places", Leagues.preset(Leagues.places))
        assertEquals("match_wins", Leagues.preset(Leagues.matchWins))
        assertEquals("custom", Leagues.preset(Leagues.places.copy(participation = 2)))
        // The rule goes back to the server in the shape it came in.
        assertEquals(p["places"], Leagues.pointsJson(Leagues.places))
        assertEquals(p["match_wins"], Leagues.pointsJson(Leagues.matchWins))
        assertEquals("""{"winners":true,"pass_down":false,"top":10}""", Leagues.qualifyJson(QualifyRule(true, false, 10)).toString())
    }

    @Test fun pointsWords() {
        for (c in cases("points_words")) assertEquals(want(c), Leagues.pointsWords(json.decodeFromJsonElement(c["rule"]!!)))
    }

    @Test fun placePoints() {
        for (c in cases("place_points")) {
            assertEquals("place ${c["place"]}", c["want"]!!.jsonPrimitive.int, Leagues.placePoints(json.decodeFromJsonElement(c["rule"]!!), c["place"]!!.jsonPrimitive.int))
        }
    }

    @Test fun qualifyWords() {
        for (c in cases("qualify_words")) assertEquals(want(c), Leagues.qualifyWords(json.decodeFromJsonElement(c["qualify"]!!)))
    }

    private fun event(o: JsonObject) = FoundEvent(
        eventId = "e", name = o["name"]!!.jsonPrimitive.content, formatLabel = o["format_label"]!!.jsonPrimitive.content,
        status = o["status"]!!.jsonPrimitive.content, currentRound = o["current_round"]!!.jsonPrimitive.int, venueName = str(o["venue_name"]),
        capacity = int(o["capacity"]), players = o["players"]!!.jsonPrimitive.int, km = int(o["km"]),
        visibility = o["visibility"]!!.jsonPrimitive.content,
        league = o["league"]?.takeIf { it !is JsonNull }?.let { EventLeague(name = it.jsonObject["name"]!!.jsonPrimitive.content) },
    )

    @Test fun rowLabel() {
        for (c in cases("row_label")) assertEquals(want(c), event(c["event"]!!.jsonObject).label)
    }

    @Test fun eventLine() {
        for (c in cases("event_line")) {
            val e = event(c["event"]!!.jsonObject)
            assertEquals(want(c), Leagues.eventLine(e.status, e.currentRound, e.formatLabel, e.venueName, e.capacity, e.players, e.km, str(c["when"])))
        }
    }

    /** The date piece the cases take as given: in the device's zone, the locale's clock. */
    @Test fun whenText() {
        val at = OffsetDateTime.parse("2026-03-29T16:00:00+00:00").toInstant()
        assertEquals("SUN 29 MAR · 10:00", Leagues.whenText(at, ZoneId.of("America/Denver"), Locale.UK))
        assertEquals("SUN 29 MAR · 10:00 AM", Leagues.whenText(at, ZoneId.of("America/Denver"), Locale.US))
        assertEquals("SUN 29 · 18:00", Leagues.dayText(at, ZoneId.of("Europe/Stockholm"), Locale.UK))
        assertEquals("29 MAR 2026", Leagues.dateText(at, ZoneId.of("America/Denver"), Locale.UK))
        val e = FoundEvent("e", formatLabel = "Modern", startsAt = "2026-03-29T16:00:00+00:00", venueName = "MeH Games", km = 19)
        assertEquals("SUN 29 MAR · 10:00 · MODERN · MEH GAMES · 19 KM", e.line(ZoneId.of("America/Denver"), Locale.UK))
        assertEquals("1 JAN 2026 – 31 DEC 2026 · ACTIVE", Leagues.seasonLine("2026-01-01", "2026-12-31", "active", Locale.UK))
    }

    @Test fun whenWindow() {
        for (c in cases("when_window")) {
            val got = Leagues.whenWindow(c["pick"]!!.jsonPrimitive.content, OffsetDateTime.parse(c["now"]!!.jsonPrimitive.content).toInstant(),
                ZoneId.of(c["zone"]!!.jsonPrimitive.content))
            val w = c["want"]!!
            val name = "${c["pick"]} at ${c["now"]}"
            if (w is JsonNull) assertNull(name, got)
            else assertEquals(name, w.jsonArray.map { Instant.parse(it.jsonPrimitive.content) }, got?.toList())
        }
    }

    @Test fun filterLabels() {
        for (c in cases("filter_labels")) {
            val f = json.decodeFromJsonElement<FindFilters>(c["filters"]!!)
            val w = c["want"]!!.jsonObject
            val got = Leagues.filterLabels(f)
            assertEquals(str(w["format"]), got.format)
            assertEquals(str(w["where"]), got.where)
            assertEquals(str(w["when"]), got.at)
            assertEquals(str(w["more"]), got.more)
        }
    }

    @Test fun boardLine() {
        for (c in cases("board_line")) assertEquals(want(c), json.decodeFromJsonElement<BoardCard>(JsonObject(c["board"]!!.jsonObject + ("board" to Json.parseToJsonElement("\"modern\"")))).line)
    }

    @Test fun leagueLine() {
        for (c in cases("league_line")) assertEquals(want(c), json.decodeFromJsonElement<LeagueCard>(JsonObject(c["card"]!!.jsonObject + ("id" to Json.parseToJsonElement("\"l\"")))).line)
    }

    /** A profile achievement's tile (§ 7): the code, the label under it, and whether it takes the accent. */
    @Test fun achievementText() {
        for (c in cases("achievement_text")) {
            val w = c["want"]!!.jsonObject
            val got = Leagues.achievementText(json.decodeFromJsonElement<Achievement>(c["item"]!!))
            assertEquals("${c["item"]}", AchievementTile(str(w["code"])!!, str(w["label"])!!, w["accent"]!!.jsonPrimitive.boolean), got)
        }
    }

    @Test fun decodesAchievements() {
        val a = demo.profile_achievements
        assertEquals("public", a.visibility)
        assertEquals(true, a.listed)
        assertEquals(listOf("CHAMPION", "QUALIFIED", "1ST", "2 WINS", "#14", "1540"), a.items.map { Leagues.achievementText(it).code })
        assertEquals(listOf(true, false, true, false, false, false), a.items.map { Leagues.achievementText(it).accent })
        assertEquals("The Mountain Magic Series · 2025", Leagues.achievementText(a.items.first()).label)
        // Others never get a board that doesn't list you, and none while you're hidden from the boards.
        assertEquals(5, Leagues.achievementsForOthers(a).size)
        assertEquals(4, Leagues.achievementsForOthers(a.copy(listed = false)).size)
        // Someone else's profile: the items alone; a viewer the part doesn't reach reads none.
        val other = json.decodeFromString<ProfileAchievements>("""{"items":[{"kind":"board","board":"modern","label":"Modern","rank":1,"rating":1790,"matches":40,"to_go":0,"players":124},
            {"kind":"league","league_id":"l","league_slug":"mms","league_name":"MMS","season_id":"s","season_name":"2026","state":"over","rank":null,"players":40,"points":0,"wins":0,"qualified":null,"champion":true}]}""")
        assertNull(other.visibility)
        assertEquals(AchievementTile("#1", "Modern", true), Leagues.achievementText(other.items[0]))
        assertEquals(AchievementTile("CHAMPION", "MMS · 2026", true), Leagues.achievementText(other.items[1]))
        assertEquals(emptyList<Achievement>(), json.decodeFromString<ProfileAchievements>("""{"items":[]}""").items)
        assertEquals("friends", json.decodeFromString<AchievementsVisibility>("""{"visibility":"friends"}""").visibility)
    }

    // ── the filters as they go to the server and stay on the device ──

    @Test fun filtersSendOnlyWhatIsPicked() {
        val now = OffsetDateTime.parse("2026-11-13T18:30:00-07:00").toInstant()
        val zone = ZoneId.of("America/Denver")
        assertEquals("{}", FindFilters().json(now, zone).toString())
        // A distance goes only with a place; a place alone still gives every event its km.
        assertEquals("""{"formats":["modern"]}""", FindFilters(formats = listOf("modern"), km = 50).json(now, zone).toString())
        assertEquals("""{"lat":39.7,"lng":-105.0,"km":50}""", FindFilters(km = 50).json(now, zone, here = 39.7 to -105.0).toString())
        assertEquals("""{"lat":39.7,"lng":-105.0}""", FindFilters().json(now, zone, here = 39.7 to -105.0).toString())
        assertEquals("""{"from":"2026-11-14T07:00:00Z","to":"2026-11-16T07:00:00Z","q":"open","team":true,"league":true,"open":true,"scope":"friends"}""",
            FindFilters(at = "weekend", scope = "friends", team = true, league = true, open = true).json(now, zone, q = " open ").toString())
        assertEquals("{}", FindFilters().json(now, zone, q = "o").toString())
    }

    @Test fun filtersToggleAndKeep() {
        var f = FindFilters().toggle("cube").toggle("modern")
        assertEquals(listOf("modern", "cube"), f.formats)
        f = f.toggle("modern")
        assertEquals(listOf("cube"), f.formats)
        var m = FindFilters().toggleMore("public").toggleMore("team")
        assertEquals(listOf("public", "team"), m.more)
        m = m.toggleMore("friends")
        assertEquals("friends", m.scope)
        assertEquals(2, m.moreCount)
        assertTrue(m.toggleMore("any").copy(formats = emptyList()).isDefault)
        // As kept on the device, and read back; anything unknown falls away.
        val kept = Leagues.picks(setOf("cube", "modern", "nope"), 50, "weekend", setOf("friends", "open"))
        assertEquals(FindFilters(listOf("modern", "cube"), 50, "weekend", "friends", team = false, league = false, open = true), kept)
        assertEquals(FindFilters(), Leagues.picks(emptySet(), 0, null, emptySet()))
        assertEquals(FindFilters(), Leagues.picks(emptySet(), 33, "someday", emptySet()))
    }

    @Test fun smallWords() {
        assertEquals("1×", Leagues.multiplierText(1.0))
        assertEquals("1.5×", Leagues.multiplierText(1.5))
        assertEquals("1,240 / 2,000", Leagues.counter(1240, Leagues.DESCRIPTION_MAX))
        assertEquals("2ND OF 24 · MODERN · 29 MAR 2026", Leagues.finishLine(2, 24, "Modern", "29 MAR 2026"))
        assertEquals("11TH", Leagues.finishLine(11, null, null, null))
        assertEquals(listOf("1st", "2nd", "3rd", "4th", "12th", "21st", "112th"), listOf(1, 2, 3, 4, 12, 21, 112).map(Leagues::ordinal))
        assertEquals("8-4-0", Leagues.recordText(8, 4, 0))
        assertEquals(39.7, Leagues.rough(39.7392), 0.0)
        assertEquals(-105.0, Leagues.rough(-104.9903), 0.0)
        assertEquals("public", Leagues.findOf("public"))
        assertEquals("private", Leagues.findOf("link_only"))
        assertEquals("invite", Leagues.findOf("private"))
        assertEquals("nearby", Leagues.findOf("nearby"))
        assertTrue(Leagues.resultsArePublic("public", null))
        assertTrue(Leagues.resultsArePublic("friends", EventLeague(name = "MMS")))
        assertFalse(Leagues.resultsArePublic("friends", null))
        assertFalse(Leagues.resultsArePublic("link_only", null))
    }

    /** The server part may not be live: PostgREST's "no such function" hides a section instead of showing an error. */
    @Test fun aMissingFunctionIsNotAnError() {
        assertTrue(Leagues.isMissing(IllegalStateException("Could not find the function public.find_events(p_filters, p_limit) in the schema cache")))
        assertTrue(Leagues.isMissing(RuntimeException("wrapped", IllegalStateException("PGRST202"))))
        assertFalse(Leagues.isMissing(IllegalStateException("That league isn't available")))
        assertFalse(Leagues.isMissing(java.io.IOException("timeout")))
    }

    // ── the server's shapes ──

    private val demo = LeaguesDemo.decode(generateSequence(File("").absoluteFile) { it.parentFile }
        .map { File(it, "app/src/debug/assets/leagues-demo.json") }.first { it.isFile }.readText())

    @Test fun decodesFindEventsAndAbout() {
        assertEquals(8, demo.find_events.size)
        val open = demo.find_events.first { it.name == "Modern Open" }
        assertEquals("modern", open.formatKey)
        assertEquals("player", open.me)
        assertEquals(19, open.km)
        assertEquals("The Mountain Magic Series", open.league?.name)
        assertEquals("THE MOUNTAIN MAGIC SERIES", open.label)
        assertEquals("FRIENDS", demo.find_events.first { it.visibility == "friends" }.label)
        val running = demo.find_events.first { it.status == "in_progress" }
        assertEquals("NOW · ROUND 3 · LEGACY · MYTHIC GAMES · 30/32 · 4 KM", running.line())
        assertEquals(2.0, demo.find_events.first { it.name == "Pioneer 2K" }.league!!.multiplier, 0.0)
        assertTrue(demo.find_events.first { it.name == "MMS Final" }.league!!.final)
        val about = demo.about(open.eventId)
        assertTrue(about.hasAbout)
        assertEquals("1234 W 38th Ave, Denver, CO", about.venueAddress)
        assertFalse(demo.about("nope").hasAbout)
        // A whole-number multiplier and nulls, as Postgres writes them.
        val wire = """{"event_id":"e","description":null,"venue_address":null,"visibility":"public","format_key":"cube",
            "league":{"id":"l","slug":"mms","name":"MMS","season_id":"s","season":"2026","multiplier":1,"final":false},"placed":true}"""
        val a = json.decodeFromString<EventAbout>(wire)
        assertEquals(1.0, a.league!!.multiplier, 0.0)
        assertTrue(a.placed)
        assertFalse(a.hasAbout)
        assertEquals(EventListing("Doors at 9", null, "friends"), json.decodeFromString<EventListing>("""{"description":"Doors at 9","venue_address":null,"visibility":"friends"}"""))
    }

    @Test fun decodesALeague() {
        val v = demo.league_view
        assertEquals("mountain-magic-series", v.league.slug)
        assertEquals(listOf("Dana Ortiz", "Mara Lind"), v.league.organizers)
        assertTrue(v.me.following)
        assertNull(v.me.role)
        assertEquals(listOf("2026", "2025"), v.seasons.map { it.name })
        val s = v.season!!
        assertEquals(Leagues.places, s.points)
        assertNull(s.bestN)
        assertEquals("1st 12 · 2nd 10 · Top 4 8 · Top 8 6 · Top 16 3 · Others 1", Leagues.pointsWords(s.points))
        assertEquals("Event winners and the top 10 on points", Leagues.qualifyWords(s.qualify))
        assertEquals(24, v.standingsCount)
        assertEquals(24, v.standings.size)
        assertEquals(4, v.standings.count { it.qualified == "winner" })
        assertEquals(10, v.standings.count { it.qualified == "points" })
        assertNull(v.standings.first { it.key.startsWith("g:") }.userId)
        assertEquals("Ann Ito", v.myRow?.name)
        // Upcoming soonest first, then finished newest first.
        assertEquals(listOf("Modern Open", "Pioneer 2K", "MMS Final", "Vintage Open", "Pauper Open", "Team Trios", "Legacy Open", "Standard Open"),
            Leagues.ordered(v.events).map { it.name })
        val zone = ZoneId.of("America/Denver")
        assertEquals("SUN 15 NOV · 10:00 · MODERN · MEH GAMES", Leagues.leagueEventLine(v.events.first { it.name == "Modern Open" }, zone, Locale.UK))
        assertEquals("SAT 5 DEC · 10:00 · PIONEER · MYTHIC GAMES", Leagues.leagueEventLine(v.events.first { it.name == "Pioneer 2K" }, zone, Locale.UK))
        assertEquals("SAT 19 DEC · 10:00 · MODERN · MEH GAMES", Leagues.leagueEventLine(v.events.first { it.final }, zone, Locale.UK))
        assertEquals("17 OCT 2026 · VINTAGE · WON BY SAM BLACK", Leagues.leagueEventLine(v.events.first { it.name == "Vintage Open" }, zone, Locale.UK))
        assertEquals(listOf("2×", "FINAL", null), listOf(Leagues.leagueEventMark(false, 2.0), Leagues.leagueEventMark(true, 2.0), Leagues.leagueEventMark(false, 1.0)))
        assertEquals(24, demo.league_standings.size)
        // Who runs it, with ids: only for the league's own organizers (the stand-in page carries them for the tools).
        assertEquals(listOf("Dana Ortiz" to "owner", "Mara Lind" to "organizer"), v.members?.map { it.name to it.role })
        assertEquals("a1a1a1a1-0000-4000-8000-000000000011", v.members?.first()?.userId)
        assertNull(demo.leagueAs("league").members)
        assertNull(demo.leagueAs("league").me.role)
        assertEquals("owner", demo.leagueAs("organizers").me.role)
        assertEquals(2, demo.leagueAs("organizers").members?.size)
        // The owner's row menu; anyone else gets none.
        val (boss, helper) = v.members!!
        assertEquals(listOf("Make organizer" to "organizer", "Remove" to null), Leagues.memberActions("owner", boss))
        assertEquals(listOf("Make owner" to "owner", "Remove" to null), Leagues.memberActions("owner", helper))
        assertEquals(emptyList<Pair<String, String?>>(), Leagues.memberActions("organizer", helper))
        assertEquals(emptyList<Pair<String, String?>>(), Leagues.memberActions(null, helper))
        // A league with no season yet.
        val empty = json.decodeFromString<LeaguePage>("""{"league":{"id":"l","slug":"new","name":"New","description":null,"region":null,"link":null,"archived":false,"organizers":["Ann"]},
            "me":{"role":"owner","following":false,"notify":false},"seasons":[],"season":null,"events":[],"standings":[],"standings_count":0,"my_row":null}""")
        assertNull(empty.season)
        assertEquals("owner", empty.me.role)
        // `members` absent (a server before it) and null (a reader who doesn't run the league) both read as none.
        assertNull(empty.members)
        assertNull(json.decodeFromString<LeaguePage>("""{"league":{"id":"l","slug":"new","name":"New"},"members":null}""").members)
        assertEquals(listOf(LeagueMember("u1", "Ann", "owner")),
            json.decodeFromString<LeaguePage>("""{"league":{"id":"l","slug":"new","name":"New"},"members":[{"user_id":"u1","name":"Ann","role":"owner"}]}""").members)
    }

    @Test fun decodesAPlayerAndCards() {
        val p = demo.league_player
        assertEquals("Ann Ito", p.player.name)
        assertEquals(6, p.events.size)
        assertFalse(p.events.last().counted)
        assertEquals(47, p.events.filter { it.counted }.sumOf { it.points })
        val h = demo.leagues_home
        assertEquals("owner", h.mine.single().role)
        assertEquals(true, h.following.single().notify)
        assertEquals("2026 · DENVER, COLORADO · NEXT MODERN OPEN", h.following.single().line)
        assertEquals("WINTER · DENVER, COLORADO", h.found.last().line)
        assertEquals(emptyList<LeagueCard>(), demo.home("d").found)
        assertEquals(listOf("Denver Pauper League"), demo.home("pauper").found.map { it.name })
        assertEquals(LeagueMe(null, true, false), json.decodeFromString<LeagueMe>("""{"following":true,"notify":false}"""))
        val season = json.decodeFromString<LeagueSeason>("""{"id":"s","name":"2027","starts_on":"2027-01-01","ends_on":"2027-12-31","state":"upcoming",
            "points":{"places":[],"participation":1,"match_win":1},"best_n":6,"qualify":{"winners":false,"pass_down":true,"top":8},"closed":false}""")
        assertEquals(Leagues.matchWins, season.points)
        assertEquals(6, season.bestN)
    }

    @Test fun decodesBoards() {
        val b = demo.format_boards
        assertTrue(b.listed)
        assertEquals(Leagues.formatKeys.map { it.first } - "other", b.boards.map { it.board })
        assertEquals("124 LISTED · YOU 1612 · #14", b.boards.first { it.board == "modern" }.line)
        assertEquals("203 LISTED · YOU 1540 · 4 TO GO", b.boards.first { it.board == "limited" }.line)
        assertEquals("61 LISTED", b.boards.first().line)
        val l = demo.format_leaderboard
        assertEquals(124, l.count)
        assertEquals(30, l.rows.size)
        assertEquals(14, l.me?.rank)
        assertNotNull(l.rows.first().userId)
        // Signed out: names only, no `me`.
        val out = json.decodeFromString<Leaderboard>("""{"board":"modern","label":"Modern","count":1,"me":null,
            "rows":[{"rank":1,"user_id":null,"name":"Bea","avatar_url":null,"rating":1700,"matches":12,"wins":9,"losses":3,"draws":0,"events":3}]}""")
        assertNull(out.rows.single().userId)
        assertNull(out.me)
        assertEquals(FormatBoards(), json.decodeFromString<FormatBoards>("""{"listed":false,"boards":[]}"""))
        assertFalse(json.decodeFromString<LeaderboardsListed>("""{"listed":false}""").listed)
    }

    /** The stand-in page a found event opens in the Debug screens. */
    @Test fun demoFiltersLikeTheServer() {
        assertEquals(listOf("Modern Open", "MMS Final"), demo.find(FindFilters(formats = listOf("modern")), "").map { it.name })
        assertEquals(listOf("Friday draft"), demo.find(FindFilters(scope = "friends"), "").map { it.name })
        assertEquals(listOf("Team Sealed Trios"), demo.find(FindFilters(team = true), "").map { it.name })
        assertEquals(3, demo.find(FindFilters(league = true), "").size)
        assertEquals(listOf("Legacy Open", "Pioneer 2K"), demo.find(FindFilters(), "mythic").map { it.name })
        assertTrue(demo.find(FindFilters(open = true), "").none { it.name == "Pauper Weekly" || it.status != "setup" })
        assertEquals("open", demo.page(demo.find_events[1].eventId)?.signUp)
    }
}
