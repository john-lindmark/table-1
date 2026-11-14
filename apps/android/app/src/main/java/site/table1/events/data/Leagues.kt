package site.table1.events.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/*
 * Finding events, leagues and format boards (contract/public-events-leagues-2026-11-13.md): what the server answers
 * and every wording and small rule, once. The rules pass testdata/leagues/cases.json (reference make_cases.py), the
 * file iOS's Leagues.swift and the web's leagues.ts pass too. Plain Kotlin, so LeaguesTest runs without Android.
 */

/** The league an event is in, as a listing and the event page show it. */
@Serializable
data class EventLeague(
    val id: String = "",
    val slug: String = "",
    val name: String = "",
    @SerialName("season_id") val seasonId: String? = null,
    val season: String? = null,
    val multiplier: Double = 1.0,
    val final: Boolean = false,
)

/** One row of find_events. */
@Serializable
data class FoundEvent(
    @SerialName("event_id") val eventId: String,
    val name: String = "",
    @SerialName("format_key") val formatKey: String = "other",
    @SerialName("format_label") val formatLabel: String = "",
    @SerialName("set_name") val setName: String? = null,
    @SerialName("cube_name") val cubeName: String? = null,
    @SerialName("team_size") val teamSize: Int? = null,
    val status: String = "setup",
    @SerialName("current_round") val currentRound: Int = 0,
    @SerialName("starts_at") val startsAt: String? = null,
    @SerialName("venue_name") val venueName: String? = null,
    @SerialName("venue_address") val venueAddress: String? = null,
    val capacity: Int? = null,
    @SerialName("top_cut") val topCut: Int = 0,
    val visibility: String = "public",
    val players: Int = 0,
    val organizer: String? = null,
    @SerialName("has_description") val hasDescription: Boolean = false,
    val km: Int? = null,
    val league: EventLeague? = null,
    /** organizer | player | waitlisted | null */
    val me: String? = null,
) {
    /** The small label above the name: the league, else FRIENDS for a friends event. */
    val label: String? get() = Leagues.rowLabel(league?.name, visibility)

    /** `SUN 29 MAR · 10:00 · MODERN · MEH GAMES · 19 KM` in the device's zone. */
    fun line(zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        Leagues.eventLine(status, currentRound, formatLabel, venueName, capacity, players, km,
            Leagues.parseInstant(startsAt)?.let { Leagues.whenText(it, zone, locale) })
}

/** event_about: what the event page adds for anyone who can open the event. */
@Serializable
data class EventAbout(
    @SerialName("event_id") val eventId: String? = null,
    val description: String? = null,
    @SerialName("venue_address") val venueAddress: String? = null,
    val visibility: String? = null,
    @SerialName("format_key") val formatKey: String? = null,
    val league: EventLeague? = null,
    val placed: Boolean = false,
    /** The rules level: casual | competitive | null (contract/room-tools-2026-11-13.md § 4). */
    val rel: String? = null,
    @SerialName("decklist_due_at") val decklistDueAt: String? = null,
    /** Team Trios: each seat's format. */
    @SerialName("seat_formats") val seatFormats: List<String>? = null,
    @SerialName("team_signup") val teamSignup: Boolean = false,
) {
    /** `COMPETITIVE · DECKLISTS DUE SAT 14 NOV 09:30`, leading the About text; empty with neither. */
    val rulesLine: String get() = RoomRules.rulesLine(rel, RoomRules.dueText(decklistDueAt))
    val hasAbout: Boolean get() = !description.isNullOrBlank() || !venueAddress.isNullOrBlank() || rulesLine.isNotEmpty()
}

/** event_listing_set's answer. */
@Serializable
data class EventListing(
    val description: String? = null,
    @SerialName("venue_address") val venueAddress: String? = null,
    val visibility: String = "link_only",
)

@Serializable
data class PointsRule(
    val places: List<Bracket> = emptyList(),
    val participation: Int = 0,
    @SerialName("match_win") val matchWin: Int = 0,
) {
    @Serializable data class Bracket(val through: Int, val points: Int)
}

@Serializable
data class QualifyRule(
    val winners: Boolean = false,
    @SerialName("pass_down") val passDown: Boolean = true,
    val top: Int = 0,
)

@Serializable
data class LeagueInfo(
    val id: String = "",
    val slug: String = "",
    val name: String = "",
    val description: String? = null,
    val region: String? = null,
    val link: String? = null,
    val archived: Boolean = false,
    val organizers: List<String> = emptyList(),
)

@Serializable
data class LeagueMe(val role: String? = null, val following: Boolean = false, val notify: Boolean = false)

@Serializable
data class LeagueSeasonHead(
    val id: String,
    val name: String = "",
    @SerialName("starts_on") val startsOn: String = "",
    @SerialName("ends_on") val endsOn: String = "",
    /** upcoming | active | over */
    val state: String = "active",
)

@Serializable
data class LeagueSeason(
    val id: String,
    val name: String = "",
    @SerialName("starts_on") val startsOn: String = "",
    @SerialName("ends_on") val endsOn: String = "",
    val state: String = "active",
    val points: PointsRule = PointsRule(),
    @SerialName("best_n") val bestN: Int? = null,
    val qualify: QualifyRule = QualifyRule(),
    val closed: Boolean = false,
    /** What each paid entry of the season's events owes the league (contract/entry-fees-2026-11-13.md § 5). */
    @SerialName("entry_cut_cents") val entryCutCents: Int = 0,
)

@Serializable
data class LeagueEvent(
    @SerialName("event_id") val eventId: String,
    val name: String = "",
    @SerialName("format_label") val formatLabel: String? = null,
    @SerialName("format_key") val formatKey: String? = null,
    @SerialName("starts_at") val startsAt: String? = null,
    @SerialName("venue_name") val venueName: String? = null,
    val status: String = "setup",
    val multiplier: Double = 1.0,
    val final: Boolean = false,
    val players: Int = 0,
    val winner: String? = null,
) {
    val finished: Boolean get() = status == "completed" || status == "archived"
}

/** A standings row. [userId] is null for guests and for signed-out readers; [key] names the player for league_player. */
@Serializable
data class LeagueRow(
    val rank: Int = 0,
    val key: String = "",
    @SerialName("user_id") val userId: String? = null,
    val name: String = "",
    val points: Int = 0,
    val events: Int = 0,
    val wins: Int = 0,
    val best: Int? = null,
    /** winner | points | null */
    val qualified: String? = null,
)

@Serializable
data class LeaguePage(
    val league: LeagueInfo = LeagueInfo(),
    val me: LeagueMe = LeagueMe(),
    val seasons: List<LeagueSeasonHead> = emptyList(),
    val season: LeagueSeason? = null,
    val events: List<LeagueEvent> = emptyList(),
    val standings: List<LeagueRow> = emptyList(),
    @SerialName("standings_count") val standingsCount: Int = 0,
    @SerialName("my_row") val myRow: LeagueRow? = null,
    /** Who runs the league, with their ids: only for the league's own organizers, null for everyone else. */
    val members: List<LeagueMember>? = null,
)

/** One of a league's organizers as its own organizers get them. [role]: owner | organizer. */
@Serializable
data class LeagueMember(@SerialName("user_id") val userId: String, val name: String = "", val role: String = "organizer")

@Serializable
data class LeaguePlayer(val player: LeagueRow = LeagueRow(), val events: List<Event> = emptyList()) {
    @Serializable
    data class Event(
        @SerialName("event_id") val eventId: String,
        val name: String = "",
        @SerialName("format_label") val formatLabel: String? = null,
        @SerialName("starts_at") val startsAt: String? = null,
        val place: Int = 0,
        val players: Int? = null,
        @SerialName("match_wins") val matchWins: Int = 0,
        val points: Int = 0,
        /** Inside the season's best N. */
        val counted: Boolean = true,
    )
}

@Serializable
data class LeagueCard(
    val id: String,
    val slug: String = "",
    val name: String = "",
    val region: String? = null,
    val season: String? = null,
    @SerialName("next_event") val nextEvent: Next? = null,
    /** Yours: owner | organizer. */
    val role: String? = null,
    /** Following: its notifications. */
    val notify: Boolean? = null,
) {
    @Serializable
    data class Next(
        @SerialName("event_id") val eventId: String = "",
        val name: String = "",
        @SerialName("starts_at") val startsAt: String? = null,
        @SerialName("format_label") val formatLabel: String? = null,
    )

    /** `2026 · DENVER, COLORADO · NEXT MODERN OPEN`. */
    val line: String get() = Leagues.leagueLine(season, region, nextEvent?.name)
}

@Serializable
data class LeaguesHome(
    val mine: List<LeagueCard> = emptyList(),
    val following: List<LeagueCard> = emptyList(),
    val found: List<LeagueCard> = emptyList(),
)

@Serializable
data class BoardMe(
    val rating: Int = 1500,
    val matches: Int = 0,
    val wins: Int = 0,
    val losses: Int = 0,
    val draws: Int = 0,
    val events: Int = 0,
    val rank: Int? = null,
    @SerialName("to_go") val toGo: Int = 0,
)

@Serializable
data class BoardCard(val board: String, val label: String = "", val players: Int = 0, val me: BoardMe? = null) {
    /** `124 LISTED · YOU 1612 · #14`. */
    val line: String get() = Leagues.boardLine(players, me?.rating, me?.rank, me?.toGo ?: 0)
}

@Serializable
data class FormatBoards(val listed: Boolean = false, val boards: List<BoardCard> = emptyList())

@Serializable
data class Leaderboard(
    val board: String = "",
    val label: String = "",
    val count: Int = 0,
    val me: BoardMe? = null,
    val rows: List<Row> = emptyList(),
) {
    @Serializable
    data class Row(
        val rank: Int = 0,
        @SerialName("user_id") val userId: String? = null,
        val name: String = "",
        @SerialName("avatar_url") val avatarUrl: String? = null,
        val rating: Int = 0,
        val matches: Int = 0,
        val wins: Int = 0,
        val losses: Int = 0,
        val draws: Int = 0,
        val events: Int = 0,
    )
}

@Serializable
data class LeaderboardsListed(val listed: Boolean = true)

/** One profile achievement (§ 7): a league season (`kind` league) or a format board (`kind` board). */
@Serializable
data class Achievement(
    val kind: String = "league",
    @SerialName("league_id") val leagueId: String? = null,
    @SerialName("league_slug") val leagueSlug: String? = null,
    @SerialName("league_name") val leagueName: String? = null,
    @SerialName("season_id") val seasonId: String? = null,
    @SerialName("season_name") val seasonName: String? = null,
    /** upcoming | active | over */
    val state: String? = null,
    /** Null on a league item when they only played the final; on a board item when the board doesn't list them yet. */
    val rank: Int? = null,
    val players: Int? = null,
    val points: Int? = null,
    val wins: Int = 0,
    val qualified: String? = null,
    val champion: Boolean = false,
    val board: String? = null,
    val label: String? = null,
    val rating: Int? = null,
    val matches: Int? = null,
    @SerialName("to_go") val toGo: Int? = null,
) {
    val isBoard: Boolean get() = kind == "board"
}

/** profile_achievements: the items; on your own profile also who sees them and whether the boards list you. */
@Serializable
data class ProfileAchievements(val items: List<Achievement> = emptyList(), val visibility: String? = null, val listed: Boolean? = null)

@Serializable
data class AchievementsVisibility(val visibility: String = "public")

/** An achievement as a small tile: a code over a label; [accent] outlines a champion and a first place, nothing else. */
data class AchievementTile(val code: String, val label: String, val accent: Boolean)

/** The Find events picks (kept per device: `find.formats`, `find.km`, `find.when`, `find.more`). */
@Serializable
data class FindFilters(
    val formats: List<String> = emptyList(),
    val km: Int? = null,
    /** any | today | weekend | week | month */
    @SerialName("when") val at: String = "any",
    /** all | public | friends */
    val scope: String = "all",
    val team: Boolean = false,
    val league: Boolean = false,
    val open: Boolean = false,
) {
    val isDefault: Boolean get() = this == FindFilters()
    val moreCount: Int get() = listOf(team, league, open, scope != "all").count { it }

    /** A format in or out, kept in the pickers' order. */
    fun toggle(format: String): FindFilters {
        val set = if (format in formats) formats - format else formats + format
        return copy(formats = Leagues.formatKeys.map { it.first }.filter { it in set })
    }

    /** What More holds, as its picker's values: public | friends | team | league | open. */
    val more: List<String>
        get() = listOfNotNull(scope.takeIf { it != "all" }, "team".takeIf { team }, "league".takeIf { league }, "open".takeIf { open })

    /** One of More's values in or out; Public and Friends replace each other. */
    fun toggleMore(value: String): FindFilters = when (value) {
        "public", "friends" -> copy(scope = if (scope == value) "all" else value)
        "team" -> copy(team = !team)
        "league" -> copy(league = !league)
        "open" -> copy(open = !open)
        else -> copy(scope = "all", team = false, league = false, open = false)
    }

    /** find_events' `p_filters`: only what's picked. [here] gives every event its distance; `km` goes only with it. */
    fun json(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault(), here: Pair<Double, Double>? = null, q: String = ""): JsonObject =
        buildJsonObject {
            if (formats.isNotEmpty()) putJsonArray("formats") { formats.forEach { add(it) } }
            if (here != null) {
                put("lat", here.first); put("lng", here.second)
                km?.let { put("km", it) }
            }
            Leagues.whenWindow(at, now, zone)?.let { (from, to) -> put("from", from.toString()); put("to", to.toString()) }
            q.trim().takeIf { it.length >= 2 }?.let { put("q", it) }
            if (team) put("team", true)
            if (league) put("league", true)
            if (open) put("open", true)
            if (scope != "all") put("scope", scope)
        }
}

object Leagues {
    /** What an event is filtered and rated under, in the pickers' order. */
    val formatKeys = listOf(
        "standard" to "Standard", "pioneer" to "Pioneer", "modern" to "Modern", "legacy" to "Legacy", "vintage" to "Vintage",
        "pauper" to "Pauper", "premodern" to "Premodern", "canadian_highlander" to "Canadian Highlander",
        "limited" to "Limited", "cube" to "Cube", "other" to "Other",
    )

    fun label(key: String): String = formatKeys.firstOrNull { it.first == key }?.second ?: "Other"

    /** Where's distances, in km. */
    val distances = listOf(25, 50, 100, 250)

    val whens = listOf("any" to "Any time", "today" to "Today", "weekend" to "This weekend", "week" to "This week", "month" to "This month")

    /** An event's weight in its season. */
    val multipliers = listOf(1.0, 1.5, 2.0, 3.0)

    /** `1×`, `1.5×`. */
    fun multiplierText(m: Double): String = (if (m == Math.floor(m)) m.toInt().toString() else m.toString()) + "×"

    // ── points and qualification ──

    /** The MMS table: 12 / 10 / 8 / 6 / 3, 1 to play. */
    val places = PointsRule(listOf(PointsRule.Bracket(1, 12), PointsRule.Bracket(2, 10), PointsRule.Bracket(4, 8),
        PointsRule.Bracket(8, 6), PointsRule.Bracket(16, 3)), participation = 1, matchWin = 0)

    /** 1 a win + 1 to play. */
    val matchWins = PointsRule(emptyList(), participation = 1, matchWin = 1)

    /** places | match_wins | custom */
    fun preset(rule: PointsRule): String = when (rule) {
        places -> "places"
        matchWins -> "match_wins"
        else -> "custom"
    }

    /** The rule as league_season_set takes it (every key, also the zeros). */
    fun pointsJson(rule: PointsRule): JsonObject = buildJsonObject {
        putJsonArray("places") { rule.places.forEach { b -> add(buildJsonObject { put("through", b.through); put("points", b.points) }) } }
        put("participation", rule.participation)
        put("match_win", rule.matchWin)
    }

    fun qualifyJson(q: QualifyRule): JsonObject = buildJsonObject {
        put("winners", q.winners); put("pass_down", q.passDown); put("top", q.top)
    }

    fun ordinal(n: Int): String {
        if (n % 100 in 10..20) return "${n}th"
        return "$n" + when (n % 10) { 1 -> "st"; 2 -> "nd"; 3 -> "rd"; else -> "th" }
    }

    /** `1st 12 · 2nd 10 · Top 4 8 · Top 8 6 · Top 16 3 · Others 1`. A bracket one past the last is a single place. */
    fun pointsWords(rule: PointsRule): String {
        val parts = mutableListOf<String>()
        var last = 0
        for (b in rule.places) {
            parts += "${if (b.through == last + 1) ordinal(b.through) else "Top ${b.through}"} ${b.points}"
            last = b.through
        }
        if (rule.participation > 0) parts += "${if (parts.isEmpty()) "Playing" else "Others"} ${rule.participation}"
        if (rule.matchWin > 0) parts += "Match win ${rule.matchWin}"
        return parts.joinToString(" · ")
    }

    /** A finish's points before match wins and the multiplier: the first bracket that reaches it, else participation. */
    fun placePoints(rule: PointsRule, place: Int): Int = rule.places.firstOrNull { it.through >= place }?.points ?: rule.participation

    fun qualifyWords(q: QualifyRule): String = when {
        q.winners && q.top > 0 -> "Event winners and the top ${q.top} on points"
        q.winners -> "Event winners"
        q.top > 0 -> "The top ${q.top} on points"
        else -> ""
    }

    // ── found events ──

    fun rowLabel(league: String?, visibility: String?): String? =
        if (!league.isNullOrEmpty()) league.uppercase() else if (visibility == "friends") "FRIENDS" else null

    /** The data line under a found event. [at] is the date piece, already in the device's zone. */
    fun eventLine(status: String, currentRound: Int, formatLabel: String, venueName: String?, capacity: Int?, players: Int,
                  km: Int?, at: String?): String {
        val running = (status == "seated" || status == "in_progress") && currentRound > 0
        return listOfNotNull(
            if (running) "NOW · ROUND $currentRound" else at,
            formatLabel.uppercase(),
            venueName?.takeIf { it.isNotEmpty() }?.uppercase(),
            capacity?.takeIf { it > 0 }?.let { "$players/$it" },
            km?.let { "$it KM" },
        ).filter { it.isNotEmpty() }.joinToString(" · ")
    }

    fun parseInstant(s: String?): Instant? = s?.let { runCatching { java.time.OffsetDateTime.parse(it).toInstant() }.getOrNull() }

    private fun fmt(pattern: String, at: Instant, zone: ZoneId, locale: Locale) =
        DateTimeFormatter.ofPattern(pattern, locale).format(at.atZone(zone)).uppercase(locale).replace(".", "")

    /** The locale's own clock: `10:00` or `10:00 AM`. */
    fun timeText(at: Instant, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).format(at.atZone(zone))
            .replace(' ', ' ').replace(' ', ' ').uppercase(locale)

    /** `SUN 29 MAR · 10:00` in the zone. */
    fun whenText(at: Instant, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        fmt("EEE d MMM", at, zone, locale) + " · " + timeText(at, zone, locale)

    /** The widget's `SUN 29 · 10:00`. */
    fun dayText(at: Instant, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        fmt("EEE d", at, zone, locale) + " · " + timeText(at, zone, locale)

    /** `29 MAR 2026` for a finished event's day. */
    fun dateText(at: Instant, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
        fmt("d MMM yyyy", at, zone, locale)

    /** A season's `starts_on` / `ends_on` (`2026-01-01`) as `1 JAN 2026`. */
    fun seasonDay(day: String, locale: Locale = Locale.getDefault()): String =
        runCatching { DateTimeFormatter.ofPattern("d MMM yyyy", locale).format(LocalDate.parse(day.take(10))).uppercase(locale).replace(".", "") }
            .getOrDefault(day)

    /** `1 JAN 2026 – 31 DEC 2026 · ACTIVE`. */
    fun seasonLine(startsOn: String, endsOn: String, state: String?, locale: Locale = Locale.getDefault()): String =
        listOfNotNull("${seasonDay(startsOn, locale)} – ${seasonDay(endsOn, locale)}", state?.uppercase()).joinToString(" · ")

    /** [from, to) for a When pick in the zone; null for Any time. Weeks start on Monday. Local midnights, so a clock
     *  change inside the window lands on the right instant. */
    fun whenWindow(pick: String, now: Instant, zone: ZoneId): Pair<Instant, Instant>? {
        val day = now.atZone(zone).toLocalDate()
        val weekday = day.dayOfWeek.value - 1   // Monday = 0 … Sunday = 6
        val nextMonday = day.plusDays((7 - weekday).toLong())
        val (start, end) = when (pick) {
            "today" -> day to day.plusDays(1)
            "weekend" -> (if (weekday >= 5) day else day.plusDays((5 - weekday).toLong())) to nextMonday
            "week" -> day to nextMonday
            "month" -> day to day.withDayOfMonth(1).plusMonths(1)
            else -> return null
        }
        return start.atStartOfDay(zone).toInstant() to end.atStartOfDay(zone).toInstant()
    }

    data class FilterLabels(val format: String, val where: String, val at: String, val more: String)

    fun filterLabels(f: FindFilters) = FilterLabels(
        format = when (f.formats.size) { 0 -> "Any format"; 1 -> label(f.formats[0]); else -> "${f.formats.size} formats" },
        where = f.km?.let { "$it km" } ?: "Everywhere",
        at = whens.firstOrNull { it.first == f.at && it.first != "any" }?.second ?: "Any time",
        more = if (f.moreCount > 0) "More · ${f.moreCount}" else "More",
    )

    /** The picks as the device keeps them (`find.formats`, `find.km`, `find.when`, `find.more`) and back. */
    fun picks(formats: Collection<String>, km: Int, at: String?, more: Collection<String>) = FindFilters(
        formats = formatKeys.map { it.first }.filter { it in formats },
        km = km.takeIf { it in distances },
        at = at?.takeIf { w -> whens.any { it.first == w } } ?: "any",
        scope = if ("public" in more) "public" else if ("friends" in more) "friends" else "all",
        team = "team" in more, league = "league" in more, open = "open" in more,
    )

    // ── boards and league cards ──

    /** `124 LISTED · YOU 1612 · #14`; `YOU 1540 · 4 TO GO` before you're listed; nothing about you with no rated match. */
    fun boardLine(players: Int, rating: Int?, rank: Int?, toGo: Int): String = buildList {
        add("$players LISTED")
        if (rating != null) {
            add("YOU $rating")
            add(rank?.let { "#$it" } ?: if (toGo > 0) "$toGo TO GO" else "NOT LISTED")
        }
    }.joinToString(" · ")

    /** `2026 · DENVER, COLORADO · NEXT MODERN OPEN`. */
    fun leagueLine(season: String?, region: String?, next: String?): String =
        listOfNotNull(season?.uppercase(), region?.uppercase(), next?.let { "NEXT ${it.uppercase()}" }).filter { it.isNotEmpty() }.joinToString(" · ")

    /** A player's season row for one event: `2ND OF 24 · MODERN · 29 MAR 2026`. */
    fun finishLine(place: Int, players: Int?, formatLabel: String?, at: String?): String =
        listOfNotNull(ordinal(place).uppercase() + (players?.let { " OF $it" } ?: ""), formatLabel?.uppercase(), at)
            .filter { it.isNotEmpty() }.joinToString(" · ")

    /** A league event's line: `SUN 29 MAR · 10:00 · MODERN · MEH GAMES`, or once finished `29 MAR 2026 · MODERN · WON BY BEA`. */
    fun leagueEventLine(e: LeagueEvent, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String {
        val at = parseInstant(e.startsAt)
        val format = e.formatLabel ?: label(e.formatKey ?: "other")
        if (!e.finished) return eventLine(e.status, 0, format, e.venueName, null, e.players, null, at?.let { whenText(it, zone, locale) })
        return listOfNotNull(at?.let { dateText(it, zone, locale) }, format.uppercase(),
            e.winner?.takeIf { it.isNotEmpty() }?.let { "WON BY ${it.uppercase()}" }).joinToString(" · ")
    }

    /** What sets a league event apart in its season: `FINAL`, or its weight when not 1 (`2×`). */
    fun leagueEventMark(final: Boolean, multiplier: Double): String? = if (final) "FINAL" else multiplier.takeIf { it != 1.0 }?.let { multiplierText(it) }

    /** Upcoming soonest first, then finished newest first. */
    fun ordered(events: List<LeagueEvent>): List<LeagueEvent> {
        val (done, coming) = events.partition { it.finished }
        return coming.sortedBy { parseInstant(it.startsAt) ?: Instant.MAX } + done.sortedByDescending { parseInstant(it.startsAt) ?: Instant.MIN }
    }

    /** A profile achievement's tile: `CHAMPION`, `1ST`, `TOP 4`, `TOP 8`, `QUALIFIED`, `#4` (a running season), `2 WINS`
     *  over `The Mountain Magic Series · 2026`; `#14` over `Modern` (the bare rating when the board doesn't list them). */
    fun achievementText(a: Achievement): AchievementTile {
        if (a.isBoard) {
            val label = a.label ?: label(a.board ?: "other")
            val rank = a.rank?.takeIf { it > 0 } ?: return AchievementTile("${a.rating ?: 0}", label, false)
            return AchievementTile("#$rank", label, rank == 1)
        }
        val label = "${a.leagueName.orEmpty()} · ${a.seasonName.orEmpty()}"
        val rank = a.rank?.takeIf { it > 0 }
        val over = a.state == "over"
        return when {
            a.champion -> AchievementTile("CHAMPION", label, true)
            over && rank != null && rank <= 8 -> AchievementTile(if (rank == 1) "1ST" else if (rank <= 4) "TOP 4" else "TOP 8", label, rank == 1)
            !a.qualified.isNullOrEmpty() -> AchievementTile("QUALIFIED", label, false)
            rank != null && rank <= 8 -> AchievementTile("#$rank", label, false)
            else -> AchievementTile(if (a.wins == 1) "1 WIN" else "${a.wins} WINS", label, false)
        }
    }

    /** What others get of your achievements (your profile's View as): no board that doesn't list you, and no boards at
     *  all while you're hidden from them. */
    fun achievementsForOthers(a: ProfileAchievements): List<Achievement> =
        a.items.filter { !it.isBoard || (it.rank != null && a.listed != false) }

    /** The owner's menu for one organizer's row (as labels and the role to set; null = remove). A non-owner gets none. */
    fun memberActions(viewerRole: String?, member: LeagueMember): List<Pair<String, String?>> =
        if (viewerRole != "owner") emptyList()
        else listOf(if (member.role == "owner") "Make organizer" to "organizer" else "Make owner" to "owner", "Remove" to null)

    /** `8-4-0`. */
    fun recordText(wins: Int, losses: Int, draws: Int) = "$wins-$losses-$draws"

    /** A rough place: rounded to 0.1° (about 11 km), the only precision the widget's Near me ever keeps. */
    fun rough(degrees: Double): Double = Math.round(degrees * 10) / 10.0

    /** `1,240 / 2,000`. */
    fun counter(length: Int, max: Int): String = "%,d / %,d".format(Locale.US, length, max)

    const val DESCRIPTION_MAX = 2000
    const val ADDRESS_MAX = 200

    /** Said once per device at sign-up for a public or league event. */
    const val PUBLIC_NOTICE = "Results in public events are public: standings, league points and format boards. You can hide yourself from the boards in Sharing."

    // ── who can find it ──

    /** Create's and Setup's three picks, as `event_listing_set {find}` takes them. */
    val finds = listOf("public" to "Public", "friends" to "Friends", "private" to "Private")

    /** The pick a stored visibility shows as: public | friends | private (link_only) | nearby | invite (private). */
    fun findOf(visibility: String?): String = when (visibility) {
        "public" -> "public"
        "friends" -> "friends"
        "nearby" -> "nearby"
        "private" -> "invite"
        else -> "private"
    }

    /** Whether sign-up for an event says the public-results notice: listed for everyone, or in a league. */
    fun resultsArePublic(visibility: String?, league: EventLeague?): Boolean = visibility == "public" || league != null

    // ── the server part may not be live ──

    /** The function isn't on the server (PostgREST PGRST202, HTTP 404): the section hides, nothing is reported. */
    fun isMissing(error: Throwable): Boolean {
        val text = generateSequence(error) { it.cause }.take(4).joinToString(" ") { "${it.message} $it" }
        return "PGRST202" in text || "Could not find the function" in text
    }
}
