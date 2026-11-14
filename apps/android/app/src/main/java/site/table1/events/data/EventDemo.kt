package site.table1.events.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * Stand-in events for looking at entry fees, teams and the room tools without signing in (Debug:
 * `--es t1Events <screen>`; MainActivity lists the screens). You are Ann Ito. Two events: Modern Open (a league's final
 * with a $25 fee, in Setup, Live or Results) and Team Trios Open (teams sign themselves up). Changes stay in memory.
 */
object EventDemo {
    const val USER = "a0000000-0000-4000-8000-000000000001"
    const val MODERN = "e0000000-0000-4000-8000-000000000001"
    const val TRIOS = "e0000000-0000-4000-8000-000000000002"

    class Data(
        val bundle: EventBundle,
        val standings: StandingsResponse,
        var money: EventMoney,
        var room: EventRoom,
        var teams: TeamMine?,
        var about: EventAbout,
        val page: EventPage,
        var final: FinalStatus?,
        var account: PaymentsAccount,
        val eventTeams: List<EventTeam> = emptyList(),
    ) {
        /** Your participant id. */
        val me: String get() = bundle.participants.firstOrNull { it.userId == USER }?.id ?: ""

        fun setPayment(participantId: String, status: String, method: String?) {
            val o = money.organizer
            val amount = money.fee?.amountCents ?: 0
            val players = o?.players?.map { if (it.participantId == participantId) it.copy(status = status, method = method, amountCents = if (status == "paid" && method != "comp") amount else 0) else it }
            money = money.copy(
                organizer = o?.copy(players = players.orEmpty(), unpaid = players.orEmpty().count { it.status != "paid" }),
                me = money.me?.let { if (it.participantId == participantId) it.copy(status = status, method = method, canPay = status != "paid", canRefund = false) else it },
            )
        }

        fun splitPrizes(rows: List<Pair<String, Int>>?) {
            money = if (rows == null) money.copy(prizes = money.prizes.map { p -> p.copy(custom = false, amountCents = Fees.prizeAt(money.fee?.payout.orEmpty(), money.pool?.poolCents ?: 0, p.place)) })
            else money.copy(prizes = money.prizes.map { p -> rows.firstOrNull { it.first == p.participantId }?.let { p.copy(amountCents = it.second, custom = true) } ?: p })
        }

        fun extend(matchId: String, seconds: Int): RoomExtension {
            val table = bundle.rounds.flatMap { it.matches }.firstOrNull { it.id == matchId }?.tableNumber
            val next = RoomExtension(matchId, table, (room.extra(matchId) + seconds).coerceIn(0, 3600))
            room = room.copy(extensions = (room.extensions.filterNot { it.matchId == matchId } + next).filter { it.extraSeconds > 0 }.sortedBy { it.tableNumber })
            return next
        }

        private fun mate(name: String, slot: Int, user: String? = null) = TeamMate("tm-$name", user, name, slot)
        private fun full(id: String, name: String, captain: String?, code: String, mates: List<TeamMate>, size: Int) =
            SignupTeam(id, name, captain, code, TeamRules.json.encodeToJsonElement(mates), mates.size == size)

        fun createTeam(name: String): TeamMine {
            val t = teams ?: TeamMine()
            val mine = full("team-new", name.ifEmpty { "Team" }, USER, "K7QX2M9A", listOf(mate("Ann Ito", 1, USER)), t.teamSize ?: 3)
            return t.copy(team = mine, captain = true, canCreate = false, teams = t.teams + SignupTeam(mine.id, mine.name, members = JsonPrimitive(1))).also { teams = it }
        }

        fun joinTeam(code: String): TeamMine {
            val t = teams ?: TeamMine()
            if (code.trim().length != 8) throw IllegalStateException("No team has that code")
            val mine = full("team-2", "Mana Burn", "u-eli", "M4NABRN2", listOf(mate("Eli Voss", 1, "u-eli"), mate("Ann Ito", 2, USER)), t.teamSize ?: 3)
            return t.copy(team = mine, captain = false, canCreate = false).also { teams = it }
        }

        fun updateTeam(patch: JsonObject): TeamMine {
            val t = teams ?: return TeamMine()
            val team = t.team ?: return t
            var mates = team.mates
            var name = team.name
            var captain = team.captainId
            patch["name"]?.jsonPrimitive?.contentOrNull?.let { name = it }
            patch["captain"]?.jsonPrimitive?.contentOrNull?.let { captain = it }
            patch["remove"]?.jsonPrimitive?.contentOrNull?.let { gone -> mates = mates.filterNot { it.participantId == gone } }
            (patch["order"] as? JsonArray)?.map { it.jsonPrimitive.content }?.let { order -> mates = order.mapNotNull { id -> mates.firstOrNull { it.participantId == id } } }
            mates = mates.mapIndexed { i, m -> m.copy(slot = i + 1) }
            val next = full(team.id, name, captain, team.joinCode ?: "", mates, t.teamSize ?: 3)
            return t.copy(team = next, captain = captain == USER,
                teams = t.teams.map { if (it.id == team.id) SignupTeam(it.id, name, members = JsonPrimitive(mates.size), complete = next.complete) else it }).also { teams = it }
        }

        fun invite(keys: List<String>?): Int {
            val f = final ?: return 0
            var n = 0
            fun go(r: FinalRow) = if (r.userId != null && r.state == "none" && (keys == null || r.key in keys)) { n++; r.copy(state = "invited") } else r
            final = f.copy(qualified = f.qualified.map(::go), next = if (keys == null) f.next else f.next.map(::go))
            return n
        }
    }

    @Volatile var data: Data? = null
        private set
    /** setup | details | fee | qualified | live | display | players | results | player | pay | trios | teams | teampage | team | payments | ready */
    var screen: String? = null
        private set
    val shown: Boolean get() = screen != null

    /** The event the screen opens on. */
    val eventId: String get() = data?.bundle?.event?.id ?: MODERN

    /** The organizer screen's first tab for this screen (null: its own first). */
    val tab: String? get() = when (screen) {
        "details", "fee", "trios" -> "details"
        "teams" -> "teams"
        "players" -> "players"
        "results" -> "prizes"
        else -> null
    }

    fun load(screen: String) {
        this.screen = screen
        data = when (screen) {
            "trios", "teams" -> trios(organizer = true, onTeam = false)
            "teampage" -> trios(organizer = false, onTeam = false)
            "team" -> trios(organizer = false, onTeam = true)
            "live", "display", "players" -> modern("live", organizer = true)
            "results" -> modern("results", organizer = true)
            "player" -> modern("live", organizer = false)
            "pay" -> modern("setup", organizer = false)
            else -> modern("setup", organizer = true)
        }.also { if (screen == "ready") it.account = PaymentsAccount(true, true, true, true, null, enabled = true) }
    }

    private val names = listOf("Ann Ito", "Bea Lund", "Cy Okafor", "Dee Park", "Eli Voss", "Fay Moreno", "Gus Tanaka", "Hana Reyes")
    private fun pid(i: Int) = "p0000000-0000-4000-8000-00000000000$i"
    private fun uid(i: Int) = if (i == 0) USER else "a0000000-0000-4000-8000-00000000001$i"

    private fun match(event: String, round: String, table: Int, a: Int, b: Int, status: String, wa: Int = 0, wb: Int = 0, source: String? = null): MatchRow {
        val id = "$round-m$table"
        return MatchRow(id, event, round, table, status = status, version = 1, resultSource = source,
            reportedByParticipant = if (status == "reported") pid(a) else null, reportedByUser = if (status == "reported") uid(a) else null,
            sides = listOf(SideRow("$id-0", id, pid(a), 0, wa), SideRow("$id-1", id, pid(b), 1, wb)))
    }

    private fun standing(rank: Int, i: Int, w: Int, l: Int, omw: Double) =
        Standing(rank, pid(i), names[i], matchPoints = w * 3, matchWins = w, matchLosses = l, omw = omw, gw = 0.6, ogw = 0.5)

    private fun modern(phase: String, organizer: Boolean): Data {
        val now = Instant.now()
        val start = LocalDate.now().plusDays(1).atTime(10, 0).atZone(ZoneId.systemDefault()).toInstant()
        val event = EventRow(
            id = MODERN, shortCode = "MMS1", name = "Modern Open", format = "constructed",
            status = when (phase) { "live" -> "in_progress"; "results" -> "completed"; else -> "setup" },
            numberOfRounds = 3, currentRound = when (phase) { "live" -> 2; "results" -> 3; else -> 0 }, createdBy = if (organizer) USER else uid(7),
            venueName = "MeH Games", visibility = "public", formatName = "modern", formatLabel = "Modern", eventType = "constructed",
            startsAt = if (phase == "setup") start.toString() else now.minusSeconds(4800).toString(),
            topCut = if (phase == "results") 0 else 4, capacity = 16, decklists = "optional",
        )
        // You are Ann, at table 1 (an organizer who plays, or a player).
        val players = (0..7).map { i ->
            ParticipantRow(pid(i), MODERN, names[i], status = "active", userId = if (i == 6) null else uid(i))
        }
        val ids = players.map { names.indexOf(it.displayName) }
        fun pair(k: Int) = ids[k * 2] to ids.getOrElse(k * 2 + 1) { ids[0] }
        val r1 = RoundRow("r1", MODERN, 1, status = "completed", matches = (0 until ids.size / 2).map { k -> pair(k).let { (a, b) -> match(MODERN, "r1", k + 1, a, b, "confirmed", 2, k % 2) } })
        val running = RoundRow("r2", MODERN, 2, status = "active", timerEndsAt = now.plusSeconds(1920).toString(), timerStatus = "running",
            timerDurationSeconds = 3000, timerRemainingAtChange = 3000, timerLastStartedAt = now.minusSeconds(1080).toString(),
            matches = (0 until ids.size / 2).map { k ->
                val (a, b) = pair(k)
                when (k) {
                    0 -> match(MODERN, "r2", 1, a, b, "pending")
                    1 -> match(MODERN, "r2", 2, a, b, "confirmed", 2, 1)
                    2 -> match(MODERN, "r2", 3, a, b, "pending")
                    else -> match(MODERN, "r2", k + 1, a, b, "reported", 2, 0)
                }
            })
        val rounds = when (phase) {
            "live" -> listOf(r1, running)
            "results" -> listOf(r1, running.copy(status = "completed", timerStatus = "paused",
                matches = running.matches.map { m -> if (m.status == "pending") m.copy(status = "confirmed", sides = m.sides.map { it.copy(gameWins = if (it.side == 0) 2 else 1) }) else m.copy(status = "confirmed") }),
                RoundRow("r3", MODERN, 3, status = "completed", matches = (0 until ids.size / 2).map { k -> pair(k).let { (a, b) -> match(MODERN, "r3", k + 1, a, b, "confirmed", 2, 0) } }))
            else -> emptyList()
        }
        val table = if (phase == "setup") emptyList() else ids.mapIndexed { n, i -> standing(n + 1, i, maxOf(0, (if (phase == "results") 3 else 1) - n / 2), if (phase == "results") minOf(3, n / 2) else minOf(1, n / 4), 0.66 - n * 0.04) }

        val fee = EventFee(2500, "usd", "either", 24, HostKeep("percent", 10), 0, Fees.payoutPresets.getValue("top4"), 700)
        val pays = players.mapIndexed { n, p ->
            val (status, method) = when {
                phase != "setup" -> if (n == 5) "paid" to "comp" else if (n % 3 == 1) "paid" to "door" else "paid" to "app"
                n == 0 || n == 3 -> "paid" to "app"
                n == 1 -> "paid" to "door"
                n == 4 -> "pending" to "app"
                n == 5 -> "refunded" to "app"
                else -> "unpaid" to null
            }
            PlayerPayment(p.id, p.userId, p.displayName, status, method, if (status == "paid" && method != "comp") 2500 else 0)
        }
        val entries = pays.count { it.status == "paid" && it.method != "comp" }
        val pool = Fees.pool(entries, 2500, 700, "percent", 10, 0)
        val mine = pays.firstOrNull { it.participantId == pid(0) && !organizer }
        val money = EventMoney(
            fee = fee, appReady = true, pool = pool,
            me = mine?.let {
                if (screen == "pay") MyPayment(it.participantId, "unpaid", null, 0, canPay = true, canRefund = false)
                else MyPayment(it.participantId, "paid", "app", 2500, canPay = false, canRefund = phase == "setup")
            },
            prizes = if (phase != "results") emptyList() else table.take(4).mapIndexed { n, s ->
                Prize(s.participantId, null, s.displayName, n + 1, Fees.prizeAt(fee.payout, pool.poolCents, n + 1), paid = n == 0, paidHow = if (n == 0) "cash" else null)
            },
            organizer = if (organizer) MoneyOrganizer(StripeState(true, true), pays, pays.count { it.status != "paid" }) else null,
        )
        val room = if (phase != "live") EventRoom() else EventRoom(
            display = RoomDisplay("auto", "Top 4 after round 3. Lunch is at the bar."),
            extensions = listOf(RoomExtension("r2-m3", 3, 300)),
            calls = if (organizer) listOf(JudgeCall("c1", "r2-m1", 1, now.minusSeconds(130).toString(), names[ids[0]]), JudgeCall("c2", "r2-m3", 3, now.minusSeconds(20).toString(), null)) else null,
            myMatch = if (organizer) null else RoomMyMatch("r2-m1", 1, 300, false),
        ).let { r -> if (organizer) r else r.copy(extensions = listOf(RoomExtension("r2-m1", 1, 300))) }
        val league = EventLeague("l1", "mountain-magic-series", "The Mountain Magic Series", "s1", "2026", 1.0, final = phase == "setup")
        val about = EventAbout(MODERN, "Five rounds of Swiss and a top 4.\n\nDoors at 9:30, round 1 at 10:00.", "1234 W 38th Ave, Denver, CO", "public", "modern",
            league.copy(final = false), rel = "competitive", decklistDueAt = start.minusSeconds(1800).toString())
        val page = EventPage(MODERN, access = if (organizer) "organizer" else "player", shortCode = "MMS1", name = event.name, formatLabel = "Modern", status = event.status,
            startsAt = event.startsAt, venueName = event.venueName, capacity = 16, players = players.size, organizerName = "Hana Reyes", topCut = 4,
            numberOfRounds = 3, signUp = if (phase == "setup") "open" else "closed", me = if (organizer) "organizer" else "player", decklists = "optional")
        val qualified = listOf(
            FinalRow("u:1", uid(1), "Bea Lund", 1, 64, "winner", "in"), FinalRow("u:2", uid(2), "Cy Okafor", 2, 58, "winner", "in"),
            FinalRow("u:3", uid(3), "Dee Park", 3, 51, "points", "invited"), FinalRow("u:4", uid(4), "Eli Voss", 4, 47, "points", "declined"),
            FinalRow("g:gus", null, "Gus Tanaka", 5, 44, "winner", "guest"), FinalRow("u:5", uid(5), "Fay Moreno", 6, 40, "points", "none"),
            FinalRow("u:8", "u8", "Ira Novak", 7, 38, "points", "none"),
        )
        val next = listOf(FinalRow("u:9", "u9", "Jo Marsh", 8, 35, null, "none"), FinalRow("u:10", "u10", "Kit Abara", 9, 33, null, "invited"),
            FinalRow("g:lee", null, "Lee Quist", 10, 30, null, "guest"))
        return Data(EventBundle(event, players, rounds, organizer), StandingsResponse(table, topCut = event.topCut), money, room, null,
            if (phase == "setup") about.copy(league = league) else about, page, if (organizer && phase == "setup") FinalStatus("s1", qualified, next) else null,
            PaymentsAccount(connected = screen != "payments", ready = false, detailsSubmitted = false, enabled = true))
    }

    private fun trios(organizer: Boolean, onTeam: Boolean): Data {
        val start = LocalDate.now().plusDays(2).atTime(11, 0).atZone(ZoneId.systemDefault()).toInstant()
        val seats = TeamRules.defaultSeats
        val event = EventRow(id = TRIOS, shortCode = "TRIO", name = "Team Trios Open", format = "constructed", status = "setup", numberOfRounds = 3,
            createdBy = if (organizer) USER else uid(7), venueName = "MeH Games", visibility = "public", formatName = "team_trios", formatLabel = "Team Trios",
            eventType = "constructed", teamSize = 3, startsAt = start.toString(), topCut = 4, capacity = 24, seatFormats = seats, teamSignup = true)
        // Stack Overflow is complete; Mana Burn has two (you are its captain when on a team); Top Decks has one.
        val roster = listOf(Triple(1, "t1", 1), Triple(2, "t1", 2), Triple(3, "t1", 3), Triple(4, "t2", if (onTeam) 2 else 1), Triple(5, "t3", 1)) +
            if (onTeam) listOf(Triple(0, "t2", 1)) else emptyList()
        val players = roster.map { (i, team, slot) -> ParticipantRow(pid(i), TRIOS, names[i], status = "active", userId = uid(i), teamId = team, teamSlot = slot) }
        val teamNames = listOf("t1" to "Stack Overflow", "t2" to "Mana Burn", "t3" to "Top Decks")
        fun mates(team: String) = players.filter { it.teamId == team }.sortedBy { it.teamSlot }.map { TeamMate(it.id, it.userId, it.displayName, it.teamSlot) }
        fun full(team: String) = SignupTeam(team, teamNames.first { it.first == team }.second, mates(team).firstOrNull()?.userId,
            mapOf("t1" to "ST4CKOVR", "t2" to "M4NABRN2", "t3" to "T0PDECKS").getValue(team), TeamRules.json.encodeToJsonElement(mates(team)), mates(team).size == 3)
        fun brief(team: String) = SignupTeam(team, teamNames.first { it.first == team }.second, members = JsonPrimitive(mates(team).size), complete = mates(team).size == 3)
        val mine = TeamMine(teamSignup = true, teamSize = 3, seatFormats = seats, team = if (onTeam) full("t2") else null, captain = onTeam,
            canCreate = !organizer && !onTeam, teams = teamNames.map { if (organizer) full(it.first) else brief(it.first) })
        val fee = EventFee(4500, "usd", "app", 48, HostKeep("flat", 2000), 5000, Fees.payoutPresets.getValue("top2"), 0)
        val pool = Fees.pool(3, 4500, 0, "flat", 2000, 5000)
        val money = EventMoney(fee, appReady = true, pool = pool,
            me = if (onTeam) MyPayment(pid(0), "unpaid", null, 0, canPay = true) else null,
            organizer = if (organizer) MoneyOrganizer(StripeState(true, true), players.mapIndexed { n, p -> PlayerPayment(p.id, p.userId, p.displayName, if (n < 3) "paid" else "unpaid", if (n < 3) "app" else null, if (n < 3) 4500 else 0) }, players.size - 3) else null)
        val about = EventAbout(TRIOS, "Teams of three: Modern, Standard and Pioneer.", "1234 W 38th Ave, Denver, CO", "public", "other", null,
            rel = "casual", seatFormats = seats, teamSignup = true)
        val page = EventPage(TRIOS, access = if (organizer) "organizer" else if (onTeam) "player" else "link", shortCode = "TRIO", name = event.name, formatLabel = "Team Trios",
            status = "setup", startsAt = event.startsAt, venueName = event.venueName, capacity = 24, players = players.size, organizerName = "Hana Reyes",
            topCut = 4, numberOfRounds = 3, signUp = "open", me = if (organizer) "organizer" else if (onTeam) "player" else null)
        val eventTeams = teamNames.mapIndexed { n, (id, name) ->
            EventTeam(id, name, n + 1, players.filter { it.teamId == id }.sortedBy { it.teamSlot }.map { TeamMember(it.id, it.displayName, it.teamSlot, it.userId) })
        }
        return Data(EventBundle(event, players, emptyList(), organizer, teamNames.mapIndexed { n, (id, name) -> EventTeamRow(id, name, n + 1) }),
            StandingsResponse(), money, EventRoom(), mine, about, page, null, PaymentsAccount(true, true, true, true, null, enabled = true), eventTeams)
    }
}
