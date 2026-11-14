package site.table1.events.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

/**
 * Entry fees (contract/entry-fees-2026-11-13.md), teams, finals and alerts (contract/teams-finals-alerts-2026-11-13.md)
 * and the room tools (contract/room-tools-2026-11-13.md) on testdata/leagues/cases.json, the file iOS and the web
 * read, plus the server's shapes as the migrations build them and the stand-in events the Debug screens draw.
 */
class EventExtrasTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "testdata/leagues").isDirectory }
    private val all = Json.parseToJsonElement(File(root, "testdata/leagues/cases.json").readText()).jsonObject

    private fun cases(name: String) = all[name]!!.jsonArray.map { it.jsonObject }
    private fun str(e: JsonElement?) = e?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull
    private fun int(e: JsonElement?) = e?.takeIf { it !is JsonNull }?.jsonPrimitive?.intOrNull
    private fun payout(e: JsonElement?) = json.decodeFromJsonElement<List<PayoutBracket>>(e!!)

    // ── entry fees ──

    @Test fun money() {
        assertEquals(8, cases("money").size)
        for (c in cases("money")) assertEquals(str(c["want"]), Fees.money(c["cents"]!!.jsonPrimitive.content.toLong()))
        assertEquals("-$7.50", Fees.money(-750))
        // What a typed amount is, and what the field shows again.
        assertEquals(2500, Fees.cents("25"))
        assertEquals(750, Fees.cents("7.5"))
        assertEquals(140000, Fees.cents("$1,400"))
        assertEquals(50, Fees.cents(".50"))
        assertNull(Fees.cents("7.555"))
        assertNull(Fees.cents("abc"))
        assertNull(Fees.cents(""))
        assertEquals("7.50", Fees.field(750))
        assertEquals("1400", Fees.field(140000))
        assertEquals("", Fees.field(0))
    }

    @Test fun feeLineAndPayTag() {
        for (c in cases("fee_line")) {
            val fee = c["fee"]?.takeIf { it !is JsonNull }?.let { json.decodeFromJsonElement<EventFee>(it) }
            assertEquals(c.toString(), str(c["want"]), Fees.feeLine(fee))
        }
        for (c in cases("pay_tag")) {
            val p = c["payment"]!!.jsonObject
            assertEquals(c.toString(), str(c["want"]), Fees.payTag(str(p["status"])!!, str(p["method"])))
        }
        assertEquals("PAID AT THE DOOR", Fees.paidWord("door"))
        assertEquals("COMP", Fees.paidWord("comp"))
        assertEquals("PAID", Fees.paidWord("app"))
        assertEquals("PAID · CASH", Fees.prizePaidTag("cash"))
        assertEquals("PAID · STORE CREDIT", Fees.prizePaidTag("store credit"))
        assertEquals("PAID", Fees.prizePaidTag("other"))
        assertEquals("PAID", Fees.prizePaidTag(null))
        assertEquals(listOf("cash", "store credit", "other"), Fees.paidHows.map { it.first })
        assertEquals("4 players haven't paid. Pair anyway?", Fees.unpaidQuestion(4))
        assertEquals("1 player hasn't paid. Pair anyway?", Fees.unpaidQuestion(1))
    }

    @Test fun payouts() {
        val presets = all["payout_presets"]!!.jsonObject
        assertEquals(presets.keys.toList(), Fees.payoutPresets.keys.toList())
        for ((k, v) in presets) {
            assertEquals(k, payout(v), Fees.payoutPresets[k])
            assertEquals(k, Fees.preset(payout(v)))
        }
        assertEquals("custom", Fees.preset(emptyList()))
        assertEquals("custom", Fees.preset(listOf(PayoutBracket(1, 50.0), PayoutBracket(2, 50.0))))
        for (c in cases("payout_words")) {
            assertEquals(c.toString(), str(c["want"]), Fees.payoutWords(payout(c["payout"])))
            assertEquals(c.toString(), c["total"]!!.jsonPrimitive.double, Fees.payoutTotal(payout(c["payout"])), 1e-9)
        }
        for (c in cases("prize_at")) {
            assertEquals(c.toString(), int(c["want"]), Fees.prizeAt(payout(c["payout"]), int(c["pool_cents"])!!, int(c["place"])!!, int(c["share"]) ?: 1))
        }
        // The breakdown's places at a pool: each bracket's own prize.
        assertEquals(listOf("1st" to 1944, "2nd" to 1215, "3rd to 4th" to 850), Fees.places(Fees.payoutPresets.getValue("top4"), 4860))
    }

    @Test fun pool() {
        assertEquals(6, cases("pool").size)
        for (c in cases("pool")) {
            val want = json.decodeFromJsonElement<MoneyPool>(c["want"]!!)
            val got = Fees.pool(int(c["entries"])!!, int(c["amount_cents"])!!, int(c["cut_cents"])!!, str(c["keep_kind"])!!, int(c["keep_value"])!!, int(c["added_cents"])!!)
            assertEquals(c.toString(), want.copy(entries = got.entries, addedCents = got.addedCents), got)
        }
    }

    @Test fun feeGoesBackWhole() {
        val fee = EventFee(2500, "usd", "either", 24, HostKeep("percent", 10), 1000, Fees.payoutPresets.getValue("top4"), 700)
        assertEquals("""{"amount_cents":2500,"pay_mode":"either","refund_hours":24,"host_keep":{"kind":"percent","value":10},"added_cents":1000,""" +
            """"payout":[{"through":1,"percent":40.0},{"through":2,"percent":25.0},{"through":4,"percent":17.5}]}""", Fees.json(fee).toString())
        // Ask me = null; a free event with prizes is paid at the door.
        val free = Fees.json(fee.copy(amountCents = 0, payMode = "app", refundHours = null))
        assertEquals(JsonNull, free["refund_hours"])
        assertEquals("door", str(free["pay_mode"]))
        assertNull(Fees.problem(fee))
        assertNotNull(Fees.problem(fee.copy(amountCents = 20)))
        assertNotNull(Fees.problem(fee.copy(payout = listOf(PayoutBracket(1, 60.0), PayoutBracket(2, 60.0)))))
        assertNotNull(Fees.problem(fee.copy(payout = listOf(PayoutBracket(2, 30.0), PayoutBracket(2, 30.0)))))
        assertEquals("Until 48 h before", Fees.refundWords(48))
        assertEquals("Ask me", Fees.refundWords(null))
    }

    @Test fun moneyDecodesAsTheServerBuildsIt() {
        assertNull(json.decodeFromString<EventMoney>("""{"fee": null}""").fee)
        val m = json.decodeFromString<EventMoney>("""
            {"fee":{"amount_cents":2500,"currency":"usd","pay_mode":"either","refund_hours":null,"host_keep":{"kind":"percent","value":10},
                    "added_cents":0,"payout":[{"through":1,"percent":100}],"league_cut_cents":700},
             "app_ready":true,
             "pool":{"entries":3,"gross_cents":7500,"league_cut_cents":2100,"host_keep_cents":540,"added_cents":0,"pool_cents":4860},
             "me":{"status":"paid","method":"app","amount_cents":2500,"participant_id":"p1","can_pay":false,"can_refund":true},
             "prizes":[{"participant_id":"p1","user_id":null,"name":"Ana","place":1,"amount_cents":4860,"custom":false,"paid":true,"paid_how":"cash"}],
             "organizer":{"stripe":{"connected":true,"ready":false},
                          "players":[{"status":"unpaid","method":null,"amount_cents":0,"participant_id":"p2","user_id":"u2","name":"Bo"}],"unpaid":1}}
        """.trimIndent())
        assertEquals("$25 · APP OR DOOR", Fees.feeLine(m.fee))
        assertEquals(4860, m.pool?.poolCents)
        assertTrue(m.me!!.canRefund)
        assertEquals("PAID · CASH", Fees.prizePaidTag(m.prizes.single().paidHow))
        assertEquals("UNPAID", m.payment("p2")!!.let { Fees.payTag(it.status, it.method) })
        assertEquals(1, m.organizer!!.unpaid)
        assertEquals("Finish setting up", json.decodeFromString<PaymentsAccount>("""{"connected":true,"ready":false,"payouts":false,"details_submitted":false,"disabled_reason":null}""").state)
        assertEquals("Not connected", PaymentsAccount().state)
        // A league's money: the organizers' part is null for everyone else.
        val l = json.decodeFromString<LeagueMoney>("""{"entry_cut_cents":700,"pool_cents":140000,"received_cents":null,"events":null}""")
        assertEquals("$1,400", Fees.money(l.poolCents))
        assertNull(l.events)
    }

    @Test fun aRefusalShowsItsOwnWords() {
        val notSetUp = IllegalStateException("""{"error":"Payments aren't set up yet"}""")
        assertTrue(Fees.notSetUp(notSetUp))
        assertEquals(Fees.NOT_SET_UP, paymentsMessage(notSetUp))
        assertTrue(Fees.notSetUp(RuntimeException("Service unavailable (503)")))
        assertFalse(Fees.notSetUp(RuntimeException("Connect Stripe first")))
        assertEquals("Connect Stripe before taking payments in the app",
            paymentsMessage(RuntimeException("""{"error":"Connect Stripe before taking payments in the app"}""" + "\nURL: https://x")))
        assertEquals("Timed out", paymentsMessage(RuntimeException("Timed out\nURL: https://x")))
    }

    // ── teams, the cut, finals, alerts ──

    @Test fun cutChoicesAndSeats() {
        assertEquals(7, cases("cut_choices").size)
        for (c in cases("cut_choices")) {
            assertEquals(c.toString(), c["want"]!!.jsonArray.map { it.jsonPrimitive.int }, TeamRules.cutChoices(str(c["format_name"]), str(c["pairing"])))
        }
        assertEquals(all["seat_formats"]!!.jsonArray.map { it.jsonObject["key"]!!.jsonPrimitive.content to it.jsonObject["label"]!!.jsonPrimitive.content },
            TeamRules.seatFormats)
        for (c in cases("seat_label")) {
            val seats = (c["seat_formats"] as? JsonArray)?.map { it.jsonPrimitive.content }
            assertEquals(c.toString(), str(c["want"]), TeamRules.seatLabel(int(c["slot"])!!, seats))
        }
        assertEquals("Top 4", TeamRules.cutLabel(4))
        assertEquals("None", TeamRules.cutLabel(0))
        // Team Trios is a constructed event that takes any deck as a decklist.
        assertTrue(EventRow("e", "CODE", "Trios", formatName = "team_trios", teamSize = 3).isConstructed)
        assertNull(EventRules.deckFormat("team_trios"))
    }

    @Test fun teamLines() {
        for (c in cases("team_line")) {
            val t = c["team"]!!.jsonObject
            assertEquals(c.toString(), str(c["want"]), TeamRules.teamLine(int(t["members"])!!, t["complete"]!!.jsonPrimitive.booleanOrNull == true, int(c["team_size"])!!))
        }
        // team_mine: your own team in full, everyone else's as a count; organizers get every team in full.
        val mine = json.decodeFromString<TeamMine>("""
            {"team_signup":true,"team_size":3,"seat_formats":["modern","standard","pioneer"],"captain":true,"can_create":false,
             "team":{"id":"t2","name":"Mana Burn","captain_id":"u1","join_code":"M4NABRN2","complete":false,
                     "members":[{"participant_id":"p2","user_id":"u2","name":"Eli","slot":2},{"participant_id":"p1","user_id":"u1","name":"Ann","slot":1}]},
             "teams":[{"id":"t1","name":"Stack Overflow","members":3,"complete":true},{"id":"t2","name":"Mana Burn","members":2,"complete":false}]}
        """.trimIndent())
        val team = mine.team!!
        assertEquals(listOf("Ann", "Eli"), team.mates.map { it.name })
        assertEquals(2, team.count)
        assertEquals(listOf("COMPLETE", "2/3"), mine.teams.map { TeamRules.teamLine(it.count, it.complete, mine.teamSize!!) })
        assertTrue(mine.teams.all { it.mates.isEmpty() })
        assertEquals("A · MODERN", TeamRules.seatLabel(team.mates[0].slot!!, mine.seatFormats))
        assertEquals("https://table-1.site/s/ev1?team=M4NABRN2", TeamRules.teamLink("ev1", team.joinCode!!))
        // The captain's order: one member up or down a seat, seat A first.
        assertEquals(listOf("p2", "p1"), TeamRules.moved(team.mates, "p2", -1))
        assertEquals(listOf("p2", "p1"), TeamRules.moved(team.mates, "p1", 1))
        assertNull(TeamRules.moved(team.mates, "p1", -1))
        assertNull(TeamRules.moved(team.mates, "nobody", 1))
        // Leaving: the captain's confirm says who takes over.
        assertEquals("You leave the event. Eli becomes captain of Mana Burn.", TeamRules.leaveText(team, "u1"))
        assertEquals("You leave the event. Your seat on Mana Burn opens.", TeamRules.leaveText(team, "u2"))
        assertEquals("You leave the event and Solo closes.",
            TeamRules.leaveText(team.copy(name = "Solo", members = buildJsonArray { add(buildJsonObject { put("participant_id", "p1"); put("user_id", "u1"); put("name", "Ann"); put("slot", 1) }) }), "u1"))
    }

    @Test fun teamCodes() {
        assertEquals("M4NABRN2", TeamRules.parseCode("m4nabrn2"))
        assertEquals("M4NABRN2", TeamRules.parseCode(" M4NA-BRN2 "))
        assertEquals("M4NABRN2", TeamRules.parseCode("Join us: https://table-1.site/s/abc?team=M4NABRN2"))
        assertNull(TeamRules.parseCode("MMS1"))
        assertNull(TeamRules.parseCode("some long sentence without a code"))
        assertNull(TeamRules.parseCode(null))
        // The link arrives with the code; anything that isn't a code is dropped.
        assertEquals(WebLink.Standings("abc", "M4NABRN2"), WebLink.parse("https://table-1.site/s/abc?team=m4nabrn2"))
        assertEquals(WebLink.Standings("abc"), WebLink.parse("https://table-1.site/s/abc?team=nope"))
        assertEquals(WebLink.Standings("abc"), WebLink.parse("https://table-1.site/s/abc"))
        // Stripe's return pages are the browser's, never the app's.
        assertEquals(WebLink.Web, WebLink.parse("https://table-1.site/pay/done?e=abc&s=cs_1"))
        assertEquals(WebLink.Web, WebLink.parse("https://table-1.site/pay/connected"))
        assertEquals(WebLink.Web, WebLink.parse("https://table-1.site/d/abc"))
    }

    @Test fun activeTeamsCountTheCut() {
        fun p(id: String, team: String?, status: String = "active") = ParticipantRow(id, "e", id, status = status, teamId = team)
        val six = (1..6).flatMap { t -> (1..3).map { p("p$t$it", "t$t") } }
        assertEquals(6, TeamRules.activeTeams(six))
        // A team with every member dropped no longer counts; one member left still does.
        assertEquals(5, TeamRules.activeTeams(six.map { if (it.teamId == "t6") it.copy(status = "dropped") else it }))
        assertEquals(6, TeamRules.activeTeams(six.map { if (it.id == "p61" || it.id == "p62") it.copy(status = "dropped") else it }))
        val event = EventRow("e", "CODE", "Trios", formatName = "team_trios", teamSize = 3, numberOfRounds = 1, topCut = 4)
        val swiss = RoundRow("r1", "e", 1, status = "completed")
        assertEquals("cut4", EventBundle(event, six, listOf(swiss), true).nextStep)
        assertEquals("finish", EventBundle(event, six.filter { it.teamId in setOf("t1", "t2", "t3", "t4") }, listOf(swiss), true).nextStep)
        // Players, not teams, for an event of players.
        assertEquals("cut4", EventBundle(event.copy(formatName = "modern", teamSize = null), six.take(5).map { it.copy(teamId = null) }, listOf(swiss), true).nextStep)
    }

    @Test fun standingsWithATeamBracket() {
        val r = json.decodeFromString<StandingsResponse>("""
            {"standings":[],"top_cut":4,
             "teams":[{"rank":1,"team_id":"t1","name":"Stack Overflow","points":9,"wins":3,"swiss_rank":2,"playoff":"winner","members":[]}],
             "team_bracket":[{"stage":"semifinal","matches":[{"table_number":1,"status":"confirmed","winner":"t1",
               "sides":[{"seed":1,"team_id":"t1","name":"Stack Overflow","match_wins":2},{"seed":4,"team_id":"t4","name":"Top Decks","match_wins":1}],
               "matches":[{"match_id":"m1","table_number":1,"is_bye":false,"status":"confirmed","winner":"p1",
                 "sides":[{"participant_id":"p1","display_name":"Bea","slot":1,"game_wins":2},{"participant_id":"p9","display_name":"Fay","slot":1,"game_wins":0}]}]}]}]}
        """.trimIndent())
        assertEquals("winner", r.teams!!.single().playoff)
        assertEquals(2, r.teams!!.single().swissRank)
        val stage = r.teamBracket.single()
        assertEquals("Semifinals", stage.title)
        assertEquals(listOf(1, 4), stage.matches.single().sides.map { it.seed })
        assertEquals("t1", stage.matches.single().winner)
        assertEquals(1, stage.matches.single().matches.single().sides.first().slot)
    }

    @Test fun finals() {
        val f = json.decodeFromString<FinalStatus>("""
            {"season_id":"s1",
             "qualified":[{"key":"u:1","user_id":"u1","name":"Bea","rank":1,"points":64,"how":"winner","state":"in"},
                          {"key":"u:2","user_id":"u2","name":"Cy","rank":2,"points":58,"how":"points","state":"none"},
                          {"key":"g:gus","user_id":null,"name":"Gus","rank":3,"points":44,"how":"winner","state":"guest"}],
             "next":[{"key":"u:9","user_id":"u9","name":"Jo","rank":4,"points":35,"how":null,"state":"none"}]}
        """.trimIndent())
        assertEquals("1 of 3 in", f.line)
        // Invite the qualified reaches accounts that aren't in or invited: never a guest.
        assertEquals(1, f.toInvite)
        assertNull(f.next.single().how)
    }

    @Test fun alerts() {
        assertEquals(4, cases("alert_line").size)
        for (c in cases("alert_line")) assertEquals(c.toString(), str(c["want"]), TeamRules.alertLine(json.decodeFromJsonElement<EventAlerts>(c["alert"]!!)))
        val a = json.decodeFromString<EventAlerts>("""{"on":true,"formats":["modern"],"km":50,"lat":39.7,"lng":-105.0}""")
        assertTrue(a.hasArea)
        assertFalse(json.decodeFromString<EventAlerts>("""{"on":false,"formats":[],"km":null,"lat":null,"lng":null}""").hasArea)
        assertEquals(listOf(null, 25, 50, 100, 250), TeamRules.alertDistances)
    }

    // ── the room ──

    @Test fun extraTime() {
        for (c in cases("extension_text")) assertEquals(c.toString(), str(c["want"]), RoomRules.extensionText(int(c["seconds"])!!))
        // What's sent is added to the table's total, which stays 0 to 60 minutes; Take it back sends minus what it has.
        assertEquals(300, RoomRules.extendBy(300, 0))
        assertEquals(-300, RoomRules.extendBy(0, 300))
        assertEquals(120, RoomRules.extendBy(600, 3480))
        assertEquals(listOf("+3 min", "+5 min", "+10 min", "Take it back"), RoomRules.extras.map { it.second })
    }

    @Test fun judgeLine() {
        assertEquals(2, cases("judge_line").size)
        for (c in cases("judge_line")) {
            val call = json.decodeFromJsonElement<JudgeCall>(buildJsonObject { put("call_id", "c"); c["call"]!!.jsonObject.forEach { (k, v) -> put(k, v) } })
            assertEquals(c.toString(), str(c["want"]), RoomRules.judgeLine(call.tableNumber, call.by, call.calledAt, Instant.parse(str(c["now"])!!.replace("+00:00", "Z"))))
        }
        // A clock a little ahead of the server's never says a negative wait.
        assertEquals("JUDGE · TABLE 7 · NOW", RoomRules.judgeLine(7, "", "2026-11-13T18:30:00+00:00", Instant.parse("2026-11-13T18:29:50Z")))
    }

    @Test fun rulesLine() {
        assertEquals(4, cases("rules_line").size)
        for (c in cases("rules_line")) assertEquals(c.toString(), str(c["want"]), RoomRules.rulesLine(str(c["rel"]), str(c["due"])))
        assertEquals("SAT 14 NOV 09:30", RoomRules.dueText("2026-11-14T09:30:00+00:00", ZoneId.of("UTC"), Locale.US))
        assertEquals("SAT 14 NOV 02:30", RoomRules.dueText("2026-11-14T09:30:00+00:00", ZoneId.of("America/Denver"), Locale.US))
        assertNull(RoomRules.dueText(null))
        val about = json.decodeFromString<EventAbout>("""{"event_id":"e","rel":"competitive","decklist_due_at":null,"seat_formats":["modern","standard","pioneer"],"team_signup":true}""")
        assertEquals("COMPETITIVE", about.rulesLine)
        assertTrue(about.hasAbout)
        assertFalse(EventAbout("e").hasAbout)
    }

    @Test fun room() {
        val r = json.decodeFromString<EventRoom>("""
            {"display":{"show":"auto","message":null},
             "extensions":[{"match_id":"m3","table_number":3,"extra_seconds":300}],
             "calls":[{"call_id":"c1","match_id":"m7","table_number":7,"called_at":"2026-11-13T18:30:00+00:00","by":"Bea"}],
             "my_match":{"match_id":"m3","table_number":3,"extra_seconds":300,"call_open":true}}
        """.trimIndent())
        assertEquals("+5:00", RoomRules.extensionText(r.extra("m3")))
        assertEquals("", RoomRules.extensionText(r.extra("m1")))
        assertTrue(r.myMatch!!.callOpen)
        // Anyone who doesn't run the event gets no calls at all.
        assertNull(json.decodeFromString<EventRoom>("""{"display":{"show":"clock","message":"Lunch"},"extensions":[],"calls":null,"my_match":null}""").calls)
        assertEquals("24 / 140", RoomRules.counter("x".repeat(24)))
        assertEquals("https://table-1.site/d/ev1", RoomRules.displayUrl("ev1"))
        assertEquals(listOf("auto", "clock", "pairings", "standings"), RoomRules.shows.map { it.first })
    }

    @Test fun pushes() {
        // A judge call rings like a pairing and opens the event (Live, for its organizers).
        assertEquals(PushRoutes.Channel.Events, PushRoutes.channel("judge.call"))
        assertTrue(PushRoutes.Channel.Events.urgent)
        assertEquals(WebLink.Screens("events", listOf("event/ev1")), PushRoutes.link(mapOf("kind" to "judge.call", "event_id" to "ev1")))
        // A new public event near you opens the event (its page, for someone who isn't in it).
        assertEquals(PushRoutes.Channel.Events, PushRoutes.channel("event.public_new"))
        assertEquals(WebLink.Screens("events", listOf("event/ev1")), PushRoutes.link(mapOf("kind" to "event.public_new", "event_id" to "ev1")))
    }

    // ── the stand-in data the Debug screens draw ──

    @Test fun standInLeagueMoneyAndAlerts() {
        val demo = LeaguesDemo.decode(generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "app/src/debug/assets/leagues-demo.json") }.first { it.isFile }.readText())
        val money = demo.league_money
        assertEquals(700, demo.league_view.season!!.entryCutCents)
        assertEquals(money.events!!.sumOf { it.owedCents }, money.poolCents)
        assertEquals(money.events!!.sumOf { it.receivedCents }, money.receivedCents)
        assertTrue(money.events!!.all { it.owedCents == it.entries * money.entryCutCents })
        assertEquals("$1,400", Fees.money(money.poolCents))
        // Everyone gets the cut and the pool; only the league's organizers what each event owes.
        assertNull(demo.moneyAs("league").events)
        assertNull(demo.moneyAs("league").receivedCents)
        assertNotNull(demo.moneyAs("dues").events)
        assertEquals("MODERN, LIMITED · 50 KM", TeamRules.alertLine(demo.event_alerts))
        // Forgetting the area takes the distance with it (a distance needs an area).
        val forgot = demo.patchAlerts(buildJsonObject { put("place", JsonNull); put("km", JsonNull) })
        assertFalse(forgot.hasArea)
        assertEquals("MODERN, LIMITED · ANYWHERE", TeamRules.alertLine(forgot))
        assertEquals("OFF", TeamRules.alertLine(demo.patchAlerts(buildJsonObject { put("on", false) })))
    }

    @Test fun standInEvents() {
        for (screen in listOf("setup", "details", "fee", "qualified", "live", "display", "players", "results", "player", "pay", "trios", "teams", "teampage", "team", "payments", "ready")) {
            EventDemo.load(screen)
            val d = EventDemo.data!!
            val fee = d.money.fee!!
            // The pool is the fee's own sum, and prizes never pass it.
            val paid = d.money.organizer?.players?.count { it.status == "paid" && it.method != "comp" }
            if (paid != null) assertEquals(screen, Fees.pool(paid, fee.amountCents, fee.leagueCutCents, fee.hostKeep.kind, fee.hostKeep.value, fee.addedCents), d.money.pool)
            assertTrue(screen, d.money.prizes.sumOf { it.amountCents } <= (d.money.pool?.poolCents ?: 0))
            assertNull(screen, Fees.problem(fee))
            // Every match's players are in the event; the room's tables are this round's.
            val ids = d.bundle.participants.map { it.id }.toSet()
            assertTrue(screen, d.bundle.rounds.flatMap { it.matches }.flatMap { it.sides }.all { it.participantId in ids })
            val live = d.bundle.activeRound?.matches?.map { it.id }.orEmpty()
            assertTrue(screen, d.room.extensions.all { it.matchId in live } && d.room.calls.orEmpty().all { it.matchId in live })
            d.teams?.team?.let { t -> assertEquals(screen, t.count, d.bundle.participants.count { it.teamId == t.id }) }
        }
        EventDemo.load("teampage")
        val d = EventDemo.data!!
        assertTrue(d.teams!!.canCreate)
        assertEquals(1, d.createTeam("Card Sharks").team!!.count)
        EventDemo.load("team")
        val t = EventDemo.data!!
        val mates = t.teams!!.team!!.mates
        assertEquals(listOf(1, 2), t.updateTeam(buildJsonObject { put("order", buildJsonArray { mates.reversed().forEach { add(kotlinx.serialization.json.JsonPrimitive(it.participantId)) } }) }).team!!.mates.map { it.slot })
        EventDemo.load("setup")
        val f = EventDemo.data!!
        assertEquals(2, f.invite(null))
        assertEquals(0, f.final!!.toInvite)
    }
}
