package site.table1.events.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import site.table1.events.data.Achievement
import site.table1.events.data.Leagues
import site.table1.events.data.ProfileAchievements
import site.table1.events.data.Repo
import site.table1.events.data.profileAchievements
import site.table1.events.data.setAchievementsVisibility
import site.table1.events.library.SharePart
import site.table1.events.library.Sharing
import site.table1.events.library.SharingRules
import site.table1.events.library.Visibility
import site.table1.events.library.WideningConfirm
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled

/*
 * Achievements on profiles (contract/public-events-leagues-2026-11-13.md § 7): a row of small tiles under the name
 * and record (league finishes and board ranks), and who sees them in Account → Sharing. A failed or missing call
 * (the server part may not be live) draws nothing.
 */

/** Where a tapped tile goes: the league on that season, or the board. */
fun achievementRoute(a: Achievement): String? =
    if (a.isBoard) a.board?.let { "board/$it" }
    else (a.leagueSlug?.takeIf { it.isNotEmpty() } ?: a.leagueId)?.let { leagueRoute(it, "profile", a.seasonId) }

/** One tile: the code over its label; the accent outline marks a champion and a first place. */
@Composable
fun AchievementTileView(a: Achievement, onClick: (() -> Unit)?) {
    val t = Leagues.achievementText(a)
    Column(Modifier.width(148.dp).height(72.dp).background(T1.surface)
        .let { if (t.accent) it.border(1.dp, T1.accent) else it }
        .let { if (onClick != null) it.clickable(onClick = onClick) else it }
        .semantics { contentDescription = "${t.code}, ${t.label}" }
        .padding(horizontal = 12.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(t.code, color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.sp, maxLines = 1)
        Text(t.label.uppercase(), color = T1.muted, fontFamily = T1.mono, fontSize = 9.sp, letterSpacing = 1.5.sp, lineHeight = 13.sp, maxLines = 2,
            overflow = TextOverflow.Ellipsis)
    }
}

/** The tiles, scrolling sideways, 1 dp apart. */
@Composable
fun AchievementTiles(items: List<Achievement>, go: (String) -> Unit) {
    if (items.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Section("Achievements")
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            items.forEach { a ->
                val route = achievementRoute(a)
                AchievementTileView(a, route?.let { r -> { Telemetry.capture("achievement_opened", mapOf("kind" to a.kind)); go(r) } })
            }
        }
    }
}

/**
 * A profile's Achievements. [viewAs]: 2 = as the server gave them; on your own profile 1 (a friend) or 0 (anyone)
 * draws what that viewer would get, from [sharing]'s profile cap and your achievements' own setting.
 */
@Composable
fun ProfileAchievementsRow(userId: String, viewAs: Int, sharing: Sharing?, go: (String) -> Unit) {
    var data by remember(userId) { mutableStateOf<ProfileAchievements?>(null) }
    LaunchedEffect(userId) { runCatching { Repo.profileAchievements(userId) }.onSuccess { data = it }.onFailure { it.rethrowIfCancelled() } }
    val d = data ?: return
    val items = if (viewAs >= 2) d.items else {
        val profile = sharing?.own(SharePart.Profile) ?: return
        if (!SharingRules.sees(viewAs, profile, Visibility.of(d.visibility) ?: Visibility.Public)) return
        Leagues.achievementsForOthers(d)
    }
    AchievementTiles(items, go)
}

/** Account → Sharing → Achievements: Private | Friends | Anyone, with the widening confirm the other parts have. */
@Composable
fun AchievementsControl(settings: Sharing, confirm: WideningConfirm) {
    val scope = rememberCoroutineScope()
    val me = Repo.userId ?: return
    var own by remember { mutableStateOf<Visibility?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(me) {
        runCatching { Repo.profileAchievements(me) }.onSuccess { own = Visibility.of(it.visibility) ?: Visibility.Public }.onFailure { it.rethrowIfCancelled() }
    }
    val v = own ?: return
    fun set(next: Visibility) {
        if (next == v) return
        // What newly reaches friends or anyone asks first, as every other part does.
        val wider = SharingRules.reach(settings, next).asks < SharingRules.reach(settings, v).asks
        val what = listOf("your league finishes and board ranks")
        val w = if (!wider) SharingRules.Widening()
                else if (SharingRules.reach(settings, next) == Visibility.Public) SharingRules.Widening(anyone = what) else SharingRules.Widening(friends = what)
        confirm.ask(w) {
            own = next
            scope.launch {
                runCatching { Repo.setAchievementsVisibility(next.wire) }.onSuccess { own = Visibility.of(it) ?: next; error = null }
                    .onFailure { it.rethrowIfCancelled(); own = v; error = userMessage(it) }
            }
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        ListRow("Achievements", "League finishes and board ranks") { Label(v.label, color = if (v == Visibility.Private) T1.muted else T1.accent) }
        T1Segmented(Visibility.entries.map { it.label }, Visibility.entries.indexOf(v)) { set(Visibility.entries[it]) }
        if (SharingRules.capped(settings, v)) {
            Notice("Set to ${v.label}, but only ${if (SharingRules.reach(settings, v) == Visibility.Friends) "friends see" else "you see"} it: your profile is " +
                "${settings.own(SharePart.Profile)!!.label}.")
        }
        error?.let { Notice(it, error = true) }
    }
}
