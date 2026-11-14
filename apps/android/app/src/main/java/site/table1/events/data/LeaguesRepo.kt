package site.table1.events.data

import android.content.Context
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.util.Telemetry

/*
 * The calls behind finding events, leagues and format boards (contract/public-events-leagues-2026-11-13.md §§ 1, 3, 4).
 * The server part may not be live yet: a missing function throws like any refusal, and callers ask Leagues.isMissing
 * to hide their section instead of showing an error. Nothing here reports to Sentry.
 */

private val supabase get() = T1App.supabase

/** Trimmed, or null when blank. */
private fun clean(v: String?) = v?.trim()?.ifEmpty { null }

// ── § 1 finding events ──

/** The events you can find, soonest first (public ones signed out). [here] = (lat, lng), never stored. */
suspend fun Repo.findEvents(filters: FindFilters, q: String = "", here: Pair<Double, Double>? = null, limit: Int = 50): List<FoundEvent> {
    LeaguesDemo.data?.let { return it.find(filters, q) }
    return supabase.postgrest.rpc("find_events", buildJsonObject {
        put("p_filters", filters.json(here = here, q = q))
        put("p_limit", limit)
    }).decodeList<FoundEvent>()
}

/** Description, address, league and format key, for anyone who can open the event. */
suspend fun Repo.eventAbout(eventId: String): EventAbout {
    EventDemo.data?.let { return it.about }
    LeaguesDemo.data?.let { return it.about(eventId) }
    return supabase.postgrest.rpc("event_about", buildJsonObject { put("p_event_id", eventId) }).decodeAs<EventAbout>()
}

/**
 * Organizers: who can find it ([find] public | friends | private), the description and the address (blank clears),
 * and the event's place for distance. Only the keys given are sent.
 */
suspend fun Repo.setEventListing(eventId: String, find: String? = null, description: String? = null, address: String? = null,
                                 place: Pair<Double, Double>? = null): EventListing {
    val r = supabase.postgrest.rpc("event_listing_set", buildJsonObject {
        put("p_event_id", eventId)
        put("p_patch", buildJsonObject {
            find?.let { put("find", it) }
            description?.let { put("description", it) }
            address?.let { put("venue_address", it) }
            place?.let { put("lat", it.first); put("lng", it.second) }
        })
    }).decodeAs<EventListing>()
    Telemetry.capture("event_listing_saved", mapOf("find" to (find ?: "kept"), "description" to !r.description.isNullOrBlank()))
    return r
}

// ── § 3 leagues ──

suspend fun Repo.leaguesHome(query: String = ""): LeaguesHome {
    LeaguesDemo.data?.let { return it.home(query) }
    return supabase.postgrest.rpc("leagues_home", buildJsonObject {
        clean(query)?.let { put("p_query", it) } ?: put("p_query", JsonNull)
    }).decodeAs<LeaguesHome>()
}

/** A league page by id or slug; [seasonId] null = the active season, else the latest over, else the next. */
suspend fun Repo.leagueView(league: String, seasonId: String? = null): LeaguePage {
    LeaguesDemo.data?.let { return it.leagueAs(LeaguesDemo.screen) }
    return supabase.postgrest.rpc("league_view", buildJsonObject {
        put("p_league", league)
        seasonId?.let { put("p_season_id", it) } ?: put("p_season_id", JsonNull)
    }).decodeAs<LeaguePage>()
}

suspend fun Repo.leagueStandings(seasonId: String, after: Int = 0, limit: Int = 100): List<LeagueRow> {
    LeaguesDemo.data?.let { return it.standings.drop(after).take(limit) }
    return supabase.postgrest.rpc("league_standings", buildJsonObject {
        put("p_season_id", seasonId); put("p_after", after); put("p_limit", limit)
    }).decodeList<LeagueRow>()
}

suspend fun Repo.leaguePlayer(seasonId: String, key: String): LeaguePlayer {
    LeaguesDemo.data?.let { return it.player(key) }
    return supabase.postgrest.rpc("league_player", buildJsonObject { put("p_season_id", seasonId); put("p_key", key) }).decodeAs<LeaguePlayer>()
}

/** Follow or unfollow; [notify] turns its notifications on or off (null keeps). */
suspend fun Repo.setLeagueFollow(leagueId: String, follow: Boolean, notify: Boolean? = null): LeagueMe {
    LeaguesDemo.data?.let { return LeagueMe(null, follow, follow && (notify ?: true)) }
    val r = supabase.postgrest.rpc("league_follow_set", buildJsonObject {
        put("p_league_id", leagueId); put("p_follow", follow)
        if (notify == null) put("p_notify", JsonNull) else put("p_notify", notify)
    }).decodeAs<LeagueMe>()
    if (notify == null) Telemetry.capture("league_followed", mapOf("following" to r.following))
    return r
}

suspend fun Repo.createLeague(name: String, description: String, region: String, link: String): LeagueInfo {
    val r = supabase.postgrest.rpc("league_create", buildJsonObject {
        put("p_name", name.trim())
        put("p_description", clean(description))
        put("p_region", clean(region))
        put("p_link", clean(link))
    }).decodeAs<LeagueInfo>()
    Telemetry.capture("league_created")
    return r
}

/** [patch] keys: name, description, region, link, archived (owner only). */
suspend fun Repo.updateLeague(leagueId: String, patch: JsonObject): LeagueInfo =
    supabase.postgrest.rpc("league_update", buildJsonObject { put("p_league_id", leagueId); put("p_patch", patch) }).decodeAs<LeagueInfo>()

/** The owner adds an organizer or removes one ([role] null). */
suspend fun Repo.setLeagueMember(leagueId: String, userId: String, role: String?) {
    supabase.postgrest.rpc("league_member_set", buildJsonObject {
        put("p_league_id", leagueId); put("p_user_id", userId)
        if (role == null) put("p_role", JsonNull) else put("p_role", role)
    })
}

/** Adds a season ([seasonId] null: needs name, dates and points) or changes one. [preset] is telemetry's. */
suspend fun Repo.setLeagueSeason(leagueId: String, seasonId: String?, patch: JsonObject, preset: String? = null): LeagueSeason {
    val r = supabase.postgrest.rpc("league_season_set", buildJsonObject {
        put("p_league_id", leagueId)
        if (seasonId == null) put("p_season_id", JsonNull) else put("p_season_id", seasonId)
        put("p_patch", patch)
    }).decodeAs<LeagueSeason>()
    Telemetry.capture("league_season_saved", mapOf("preset" to (preset ?: Leagues.preset(r.points))))
    return r
}

@Serializable
private data class LeagueEventSet(val league: EventLeague? = null)

/** Puts an event in a season, or takes it out ([seasonId] null). The caller runs both the event and the league. */
suspend fun Repo.setLeagueEvent(eventId: String, seasonId: String?, multiplier: Double = 1.0, final: Boolean = false): EventLeague? {
    val r = supabase.postgrest.rpc("league_event_set", buildJsonObject {
        put("p_event_id", eventId)
        if (seasonId == null) put("p_season_id", JsonNull) else put("p_season_id", seasonId)
        put("p_multiplier", multiplier); put("p_final", final)
    }).decodeAs<LeagueEventSet>()
    Telemetry.capture("league_event_set", mapOf("final" to final, "multiplier" to multiplier, "removed" to (seasonId == null)))
    return r.league
}

// ── § 4 format boards ──

suspend fun Repo.formatBoards(): FormatBoards {
    LeaguesDemo.data?.let { return it.boards }
    return supabase.postgrest.rpc("format_boards").decodeAs<FormatBoards>()
}

suspend fun Repo.formatLeaderboard(board: String, after: Int = 0, limit: Int = 100): Leaderboard {
    LeaguesDemo.data?.let { return it.board(board, after) }
    return supabase.postgrest.rpc("format_leaderboard", buildJsonObject {
        put("p_board", board); put("p_after", after); put("p_limit", limit)
    }).decodeAs<Leaderboard>()
}

/** Hide or show yourself on every board. */
suspend fun Repo.setLeaderboardsListed(listed: Boolean): Boolean {
    val r = supabase.postgrest.rpc("leaderboards_listed_set", buildJsonObject { put("p_listed", listed) }).decodeAs<LeaderboardsListed>()
    Telemetry.capture("leaderboards_listed", mapOf("listed" to r.listed))
    return r.listed
}

// ── § 7 achievements on profiles ──

/** A profile's achievements; on your own also who sees them (`visibility`) and whether the boards list you. */
suspend fun Repo.profileAchievements(userId: String): ProfileAchievements {
    LeaguesDemo.data?.let { return it.profile_achievements }
    return supabase.postgrest.rpc("profile_achievements", buildJsonObject { put("p_user_id", userId) }).decodeAs<ProfileAchievements>()
}

/** Who sees your achievements: private | friends | public. */
suspend fun Repo.setAchievementsVisibility(visibility: String): String {
    val r = supabase.postgrest.rpc("achievements_visibility_set", buildJsonObject { put("p_visibility", visibility) }).decodeAs<AchievementsVisibility>()
    Telemetry.capture("achievements_visibility", mapOf("visibility" to r.visibility))
    return r.visibility
}

/**
 * Stand-in data for looking at the new screens without signing in (Debug: `--es t1Leagues <screen>`), like iOS's
 * LeaguesDemo: a year-long season on the MMS table (12 / 10 / 8 / 6 / 3, 1 to play), winners qualify, top 10 on
 * points. Read from src/debug/assets/leagues-demo.json, the fixture LeaguesTest decodes; Release builds don't carry it.
 */
object LeaguesDemo {
    @Serializable
    data class Data(
        val find_events: List<FoundEvent> = emptyList(),
        val event_about: Map<String, EventAbout> = emptyMap(),
        val league_view: LeaguePage = LeaguePage(),
        val league_standings: List<LeagueRow> = emptyList(),
        val league_player: LeaguePlayer = LeaguePlayer(),
        val leagues_home: LeaguesHome = LeaguesHome(),
        val format_boards: FormatBoards = FormatBoards(),
        val format_leaderboard: Leaderboard = Leaderboard(),
        val profile_achievements: ProfileAchievements = ProfileAchievements(),
        val league_money: LeagueMoney = LeagueMoney(),
        val event_alerts: EventAlerts = EventAlerts(),
    ) {
        /** league_money as its reader gets it: what each event owes only for the league's own organizers. */
        fun moneyAs(screen: String?): LeagueMoney =
            if (screen == "tools" || screen == "organizers" || screen == "dues") league_money else league_money.copy(receivedCents = null, events = null)

        val alerts: EventAlerts get() = alertsNow ?: event_alerts

        /** event_alerts_set on the stand-in setting. */
        fun patchAlerts(patch: JsonObject): EventAlerts {
            var a = alerts
            (patch["on"] as? kotlinx.serialization.json.JsonPrimitive)?.let { a = a.copy(on = it.content == "true") }
            (patch["formats"] as? kotlinx.serialization.json.JsonArray)?.let { f -> a = a.copy(formats = f.map { (it as kotlinx.serialization.json.JsonPrimitive).content }) }
            if ("km" in patch) a = a.copy(km = (patch["km"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toIntOrNull())
            if ("lat" in patch) a = a.copy(lat = 39.7, lng = -105.0)
            if ("place" in patch) a = a.copy(lat = null, lng = null, km = null)
            alertsNow = a
            return a
        }

        val league get() = league_view

        /** The league as its reader gets it: the organizer tools' screens read it as the owner, everyone else without
         *  `members`, as the server answers. */
        fun leagueAs(screen: String?): LeaguePage =
            if (screen == "tools" || screen == "organizers" || screen == "dues") league_view.copy(me = league_view.me.copy(role = "owner"))
            else league_view.copy(members = null)
        val standings get() = league_standings
        val boards get() = format_boards

        /** The filters the server would apply, as far as the stand-in rows can show them. */
        fun find(f: FindFilters, q: String): List<FoundEvent> = find_events.filter { e ->
            (f.formats.isEmpty() || e.formatKey in f.formats) && (f.km == null || (e.km != null && e.km <= f.km)) &&
                (f.scope == "all" || e.visibility == f.scope) && (!f.team || e.teamSize != null) && (!f.league || e.league != null) &&
                (!f.open || (e.status == "setup" && (e.capacity == null || e.players < e.capacity))) &&
                (q.trim().length < 2 || listOfNotNull(e.name, e.venueName, e.league?.name).any { it.contains(q.trim(), ignoreCase = true) })
        }

        fun about(eventId: String): EventAbout = event_about[eventId]
            ?: find_events.firstOrNull { it.eventId == eventId }?.let { EventAbout(eventId, null, it.venueAddress, it.visibility, it.formatKey, it.league) }
            ?: EventAbout(eventId)

        fun home(query: String): LeaguesHome = leagues_home.copy(found = if (query.trim().length < 2) emptyList()
            else leagues_home.found.filter { it.name.contains(query.trim(), true) || it.region.orEmpty().contains(query.trim(), true) })

        fun player(key: String): LeaguePlayer =
            league_standings.firstOrNull { it.key == key }?.let { row ->
                if (row.key == league_player.player.key) league_player
                else league_player.copy(player = row, events = league_player.events.take(row.events.coerceAtLeast(1)))
            } ?: league_player

        fun board(key: String, after: Int): Leaderboard =
            format_leaderboard.copy(board = key, label = Leagues.label(key), rows = format_leaderboard.rows.drop(after))

        /** The event page behind a found event (event_public's shape), sign-up open. */
        fun page(eventId: String): EventPage? = find_events.firstOrNull { it.eventId == eventId }?.let { e ->
            EventPage(eventId = e.eventId, access = "link", shortCode = "MMS1", name = e.name, formatLabel = e.formatLabel, status = e.status,
                startsAt = e.startsAt, venueName = e.venueName, capacity = e.capacity, players = e.players, organizerName = e.organizer,
                topCut = e.topCut, numberOfRounds = 5, signUp = "open", me = e.me.takeIf { it == "player" })
        }
    }

    val json = Json { ignoreUnknownKeys = true }

    /** The stand-in alert setting after a change on the Alerts screen. */
    private var alertsNow: EventAlerts? = null

    /** Set by MainActivity in debuggable builds only. */
    @Volatile var data: Data? = null
        private set
    /** The screen `--es t1Leagues` asked for: find | leagues | boards | league | player | standings | details | board | event | create | season | tools | organizers | home | profile | live. */
    var screen: String? = null
        private set

    /** Stand-in data is answering. */
    val on: Boolean get() = data != null
    /** The Debug screens are up: on stand-in data, or (`live`) signed out against the real server, to see what a
     *  server without these functions draws. */
    val shown: Boolean get() = screen != null

    fun decode(raw: String): Data = json.decodeFromString(Data.serializer(), raw)

    fun load(context: Context, screen: String) {
        data = if (screen == "live") null
               else runCatching { decode(context.assets.open("leagues-demo.json").bufferedReader().use { it.readText() }) }.getOrNull()
        this.screen = screen
    }
}
