package site.table1.events.ui

import android.net.Uri
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import site.table1.events.T1App
import site.table1.events.data.JoinLink
import site.table1.events.data.WebLink
import site.table1.events.openInBrowser
import site.table1.events.data.Repo
import site.table1.events.library.RankingsScreen
import site.table1.events.library.SharedLinkScreen
import site.table1.events.library.BuyScreen
import site.table1.events.library.FollowsStore
import site.table1.events.library.T1Icon
import site.table1.events.library.GuideSide
import site.table1.events.library.NewMatchupScreen
import site.table1.events.library.SideboardGuideScreen
import site.table1.events.library.SideboardMatchupScreen
import site.table1.events.library.SideboardPickScreen
import site.table1.events.library.SideboardPoolScreen
import site.table1.events.library.SideboardPrintScreen
import site.table1.events.library.WantPricesStore
import site.table1.events.library.FollowingScreen
import site.table1.events.library.FollowChangesScreen
import site.table1.events.library.RankingScreen
import site.table1.events.library.RankingPickScreen
import site.table1.events.library.RankingListsScreen
import site.table1.events.library.RankingCardScreen
import site.table1.events.library.RankingCompareScreen
import site.table1.events.library.RankingPackScreen
import site.table1.events.library.RankingChangesScreen
import site.table1.events.library.RankJob
import site.table1.events.library.AddCardsScreen
import site.table1.events.library.AllCardsScreen
import site.table1.events.library.CardContext
import site.table1.events.library.CardDetailScreen
import site.table1.events.library.CatalogStore
import site.table1.events.library.CollectionStore
import site.table1.events.library.DeckFinderScreen
import site.table1.events.library.LibraryHomeScreen
import site.table1.events.library.BindersStore
import site.table1.events.library.HeroesStore
import site.table1.events.library.BindersScreen
import site.table1.events.library.BinderScreen
import site.table1.events.library.WantsScreen
import site.table1.events.library.UNSORTED
import site.table1.events.library.CollectionImportScreen
import site.table1.events.library.TradeScreen
import site.table1.events.library.TradesScreen
import site.table1.events.library.TradesStore
import site.table1.events.library.ChangePrintingScreen
import site.table1.events.library.PrintingTarget
import site.table1.events.library.ListImportScreen
import site.table1.events.library.ListAddScreen
import site.table1.events.library.ListDetailScreen
import site.table1.events.library.CubeSyncScreen
import site.table1.events.library.ListStatsScreen
import site.table1.events.library.SampleHandScreen
import site.table1.events.library.DrawOddsScreen
import site.table1.events.library.SamplePackScreen
import site.table1.events.library.ListKind
import site.table1.events.library.ListVersionScreen
import site.table1.events.library.ListVersionsScreen
import site.table1.events.library.ListsScreen
import site.table1.events.library.ListsStore
import site.table1.events.library.FriendAddScreen
import site.table1.events.library.FriendsScreen
import site.table1.events.library.FriendsStore
import site.table1.events.library.ProfileCardsScreen
import site.table1.events.library.ProfileFriendsScreen
import site.table1.events.library.ProfileUserScreen
import site.table1.events.library.SharingScreen
import site.table1.events.library.TradeMatchScreen
import site.table1.events.library.TradeMatchesScreen
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Tab
import site.table1.events.ui.components.T1TabBar
import site.table1.events.ui.screens.AccountScreen
import site.table1.events.ui.screens.AddPlayersScreen
import site.table1.events.ui.screens.CreateEventScreen
import site.table1.events.ui.screens.DeckPhotosScreen
import site.table1.events.ui.screens.EventScreen
import site.table1.events.ui.screens.EventPageScreen
import site.table1.events.ui.screens.EventsHomeScreen
import site.table1.events.ui.screens.NearbyScreen
import site.table1.events.auth.EmailSignIn
import site.table1.events.auth.SessionView
import site.table1.events.auth.SignIn
import site.table1.events.ui.screens.NameScreen
import site.table1.events.ui.screens.PermissionsScreen
import site.table1.events.util.PermissionsStep
import site.table1.events.ui.screens.SignInScreen
import site.table1.events.ui.tracker.LifeTrackerScreen
import site.table1.events.insights.InsightsDemoRoot
import site.table1.events.insights.InsightsStore
import site.table1.events.insights.insightsGraph
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Signed out → sign-in. Signed in → tabs Events | Collection (the Library) | Insights | Account. A QR join link that arrived before
 * sign-in (camera scan, notification) is held and completed right after.
 */
@Composable
fun AppRoot(pendingJoin: JoinLink?, onJoinConsumed: () -> Unit, pendingLink: WebLink?, onLinkConsumed: () -> Unit) {
    // Debug: `adb shell am start -n site.table1.events/.MainActivity --ez insightsDemo true` opens Insights on the demo packs.
    if (InsightsStore.demo) { InsightsDemoRoot(); return }
    val status by T1App.supabase.auth.sessionStatus.collectAsState()
    // A failed refresh (offline, 5xx) keeps the app on the session it last had (SessionView).
    var kept by remember { mutableStateOf<UserSession?>(null) }
    var keptRead by remember { mutableStateOf(false) }
    LaunchedEffect(status) {
        when (val s = status) {
            is SessionStatus.Authenticated -> { kept = s.session; keptRead = true }
            is SessionStatus.NotAuthenticated -> { kept = null; keptRead = true }
            is SessionStatus.RefreshFailure -> if (!keptRead) {
                kept = runCatching { T1App.supabase.auth.sessionManager.loadSession() }.getOrNull()
                keptRead = true
            }
            SessionStatus.Initializing -> {}
        }
    }
    val shown = SessionView.shown(status, kept, keptRead)
    // Signed in any way: the email code step kept for a return is done with.
    val signedIn = status is SessionStatus.Authenticated
    LaunchedEffect(signedIn) { if (signedIn) EmailSignIn.clear() }
    // Why notifications and location help, once per device after sign-in (and the name step), skippable.
    val rootContext = LocalContext.current
    var needsPermissions by remember { mutableStateOf(PermissionsStep.needed(rootContext)) }
    when (shown) {
        is SessionView.Shown.SignedIn ->
            if (SignIn.needsName(shown.session.user)) NameScreen(pendingJoin)
            else if (needsPermissions) PermissionsScreen { needsPermissions = false }
            else SignedInApp(pendingJoin, onJoinConsumed, pendingLink, onLinkConsumed)
        SessionView.Shown.Starting -> T1Screen { Bar("Table 1") }
        SessionView.Shown.SignedOut -> {
            // Standings tapped while the app was still starting: read them on the web rather than signing in first.
            val context = LocalContext.current
            LaunchedEffect(pendingLink) {
                // A sign-up link before round 1 (contract/scheduled-events-2026-10-27.md §4): sign in first with the
                // event over it; the link stays pending and the signed-in app signs up.
                (pendingLink as? WebLink.Standings)?.let { link ->
                    val page = runCatching { Repo.eventPage(link.eventId) }.getOrNull()
                    if (page != null && page.available && page.signUp != "closed" && page.me == null) {
                        PendingSignUp.page = page
                        return@LaunchedEffect
                    }
                }
                val url = when (val link = pendingLink) {
                    is WebLink.Standings -> WebLink.standingsUrl(link.eventId)
                    is WebLink.Shared -> WebLink.sharedUrl(link.token)
                    else -> return@LaunchedEffect
                }
                onLinkConsumed()
                openInBrowser(context, Uri.parse(url))
            }
            SignInScreen(pendingJoin)
        }
    }
}

@Composable
private fun SignedInApp(pendingJoin: JoinLink?, onJoinConsumed: () -> Unit, pendingLink: WebLink?, onLinkConsumed: () -> Unit) {
    val nav = rememberNavController()
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route
    var joinError by remember { mutableStateOf<String?>(null) }
    // While a round you're playing is running, Events opens straight into it — once per launch or return.
    var autoOpenArmed by rememberSaveable { mutableStateOf(true) }
    var foregrounds by remember { mutableIntStateOf(0) }

    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        var started = false
        var stoppedAt: Long? = null
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) stoppedAt = android.os.SystemClock.elapsedRealtime()
            if (event == Lifecycle.Event.ON_START) {
                if (started) autoOpenArmed = true
                started = true
                foregrounds++
                // Away 30 minutes or more: Events again, as after a fresh start. A tapped notification or link still
                // opens its own screen: it navigates after this.
                if (SessionView.backToEvents(stoppedAt, android.os.SystemClock.elapsedRealtime())) {
                    nav.navigate("events") { popUpTo(nav.graph.findStartDestination().id); launchSingleTop = true }
                }
                stoppedAt = null
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    suspend fun join(link: JoinLink) {
        runCatching { Repo.joinByQr(link) }
            .onSuccess { autoOpenArmed = false; nav.navigate("event/${it.eventId}") }
            .onFailure { joinError = it.message }
    }

    LaunchedEffect(pendingJoin) {
        val link = pendingJoin ?: return@LaunchedEffect
        onJoinConsumed()
        join(link)
    }

    // A tapped table-1.site link (contract/universal-links-2026-10-22.md): its tab, then the screens above it.
    val context = LocalContext.current
    fun show(tab: String, stack: List<String>) {
        nav.navigate(tab) { popUpTo(nav.graph.findStartDestination().id); launchSingleTop = true }
        stack.forEach { nav.navigate(it) }
    }
    LaunchedEffect(pendingLink) {
        val link = pendingLink ?: return@LaunchedEffect
        onLinkConsumed()
        autoOpenArmed = false
        when (link) {
            is WebLink.Screens -> show(link.tab, link.stack)
            is WebLink.Insights -> {
                InsightsStore.pickSection("constructed")
                InsightsStore.pickFormat(link.format)
                link.tier?.let(InsightsStore::pickTier)
                link.days?.let(InsightsStore::pickDays)
                show("insights", link.stack)
            }
            is WebLink.Tracker -> show("events", listOf(link.matchId?.let { "tracker/$it" } ?: "tracker"))
            is WebLink.JoinCode -> runCatching { Repo.joinByCode(link.code) }
                .onSuccess { show("events", listOf("event/${it.eventId}")) }
                .onFailure { joinError = it.message; show("events", emptyList()) }
            // Organizers and players get the event; before round 1 anyone else the sign-up page (signing up at once when
            // they came through sign-in from it); after that the public standings page.
            is WebLink.Standings -> {
                val signUp = PendingSignUp.page?.eventId == link.eventId
                PendingSignUp.page = null
                val page = runCatching { Repo.eventPage(link.eventId) }.getOrNull()
                when {
                    page?.access in setOf("organizer", "player") -> show("events", listOf("event/${link.eventId}"))
                    page != null && page.available && (page.signUp != "closed" || page.me == "waitlisted") ->
                        show("events", listOf("eventpage/${link.eventId}?signup=$signUp"))
                    else -> openInBrowser(context, Uri.parse(WebLink.standingsUrl(link.eventId)))
                }
            }
            is WebLink.Shared -> show("collection", listOf("collection/shared/${link.token}"))
            WebLink.SignIn, is WebLink.JoinQr, WebLink.Web -> {}
        }
    }

    fun tab(to: String) = nav.navigate(to) {
        popUpTo(nav.graph.findStartDestination().id) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }

    // The collection mirror syncs on open and on each return; the catalog pack is checked once a day.
    val userId = Repo.userId
    LaunchedEffect(userId) {
        // Side by side: each start reads its copy on the device, then syncs. One after another, the hero and binder
        // copies were read only once the collection and lists had synced, so the Collection home drew fallback art
        // and no binders for 5-10 s.
        if (userId != null) coroutineScope {
            launch { CollectionStore.start(userId) }
            launch { ListsStore.start(userId) }
            launch { BindersStore.start(userId) }
            launch { HeroesStore.start(userId) }
        }
        CatalogStore.load(userInitiated = false)
    }
    DisposableEffect(Unit) { onDispose { CollectionStore.stop(); ListsStore.stop(); TradesStore.stop(); BindersStore.stop(); HeroesStore.stop(); FriendsStore.stop(); FollowsStore.stop(); WantPricesStore.stop(); site.table1.events.library.ModerationStore.stop(); site.table1.events.library.BugsStore.stop() } }
    LaunchedEffect(foregrounds) {
        CatalogStore.load(userInitiated = route?.startsWith("collection") == true)
        if (foregrounds > 0) HeroesStore.refresh()
        // The live notification and the Current match widget catch up whenever the app comes back.
        site.table1.events.util.LiveUpdates.refresh(context)
    }

    val topLevel = route == "events" || route == "account" || route == "collection" || route == "insights"
    // Review (proposed archetypes and bans) shows for moderators; the server refuses anyone else.
    var moderator by remember { mutableStateOf(false) }
    LaunchedEffect(userId) {
        moderator = runCatching {
            Json.parseToJsonElement(T1App.supabase.postgrest.rpc("moderation_me").data).jsonObject["moderator"]?.jsonPrimitive?.booleanOrNull == true
        }.getOrDefault(false)
    }
    // A sharing offer made due by an action elsewhere (marking a binder For trade), shown over that screen.
    val offer by site.table1.events.library.SharingOffer.due.collectAsState()
    if (offer == site.table1.events.library.SharingOffer.ForTrade) site.table1.events.library.SharingOfferDialog(offer!!,
        "Share For trade with friends?", "Friends can see these copies, and trade matches can find you.",
        listOf(site.table1.events.library.SharePart.ForTrade)) { site.table1.events.library.SharingOffer.due.value = null }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).let { if (topLevel) it.consumeWindowInsets(WindowInsets.navigationBars) else it }) {
            // A tapped person opens their profile on this back stack (ui/components/PersonLink.kt).
            CompositionLocalProvider(site.table1.events.ui.components.LocalOpenProfile provides { id: String -> nav.navigate("profile/$id") }) {
            NavHost(navController = nav, startDestination = "events") {
                composable("events") {
                    var scanned by remember { mutableStateOf<JoinLink?>(null) }
                    LaunchedEffect(scanned) { scanned?.let { scanned = null; join(it) } }
                    if (joinError != null) {
                        T1Screen {
                            Bar("Couldn't join")
                            Notice(joinError ?: "", error = true)
                            Notice("Tap back to try again.")
                        }
                        androidx.activity.compose.BackHandler { joinError = null }
                    } else {
                        EventsHomeScreen(
                            foregrounds = foregrounds,
                            autoOpenArmed = autoOpenArmed,
                            onAutoOpened = { autoOpenArmed = false },
                            onOpenEvent = { nav.navigate("event/$it") },
                            onCreate = { nav.navigate("create") },
                            onOpenPage = { nav.navigate("eventpage/$it?signup=false") },
                            onNearby = { nav.navigate("nearby") },
                            onJoinLink = { scanned = it },
                            onLife = { nav.navigate("tracker") },
                            onOpenTracker = { matchId -> nav.navigate("tracker/$matchId") },
                        )
                    }
                }
                // Insights (contract/insights-2026-10-24.md): the metagame and Arena draft.
                insightsGraph(nav, moderator)
                composable("account") {
                    AccountScreen(foregrounds = foregrounds, onFriends = { nav.navigate("friends") }, onSharing = { nav.navigate("sharing") },
                        onProfile = { nav.navigate("profile/$it") }, onNotices = { nav.navigate("notices") }, onReview = { nav.navigate("review") }, onBugs = { nav.navigate("bugs") },
                        onDeckPhotos = { nav.navigate("mydeckphotos") })
                }
                // Account → Deck photos (contract/event-night-2026-10-16.md § 7 On your account).
                composable("mydeckphotos") {
                    site.table1.events.ui.screens.MyDeckPhotosScreen(onBack = { nav.popBackStack() },
                        onOpenEvent = { nav.navigate("event/$it") }, onOpenEventPhotos = { nav.navigate("photos/$it") })
                }
                // Moderation (contract/moderation-2026-10-18.md): notices and appeals; Review for moderators.
                composable("notices") { site.table1.events.library.NoticesScreen(onBack = { nav.popBackStack() }) }
                composable("review") { site.table1.events.library.ReviewScreen(onBack = { nav.popBackStack() }) }
                // The bug inbox (contract/bug-pipeline-2026-10-18.md § Inbox), watchers only.
                composable("bugs") { site.table1.events.library.BugsScreen(onBack = { nav.popBackStack() }, onBug = { nav.navigate("bug/$it") }) }
                composable("bug/{id}") { e ->
                    site.table1.events.library.BugScreen(e.arguments?.getString("id")?.toLongOrNull() ?: 0, onBack = { nav.popBackStack() })
                }
                // Friends, profiles, sharing and trade matches (contract/friends-sharing-2026-10-18.md).
                composable("friends") {
                    FriendsScreen(onBack = { nav.popBackStack() }, onProfile = { nav.navigate("profile/$it") }, onAdd = { nav.navigate("friends/add") })
                }
                composable("friends/add") { FriendAddScreen(onBack = { nav.popBackStack() }) }
                composable("sharing") { SharingScreen(onBack = { nav.popBackStack() }) }
                composable("profile/{id}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    ProfileUserScreen(id, onBack = { nav.popBackStack() },
                        onSection = { kind, item -> nav.navigate("profile/$id/$kind/${item ?: "-"}") },
                        onMatch = { nav.navigate("collection/match/$id") }, onSharing = { nav.navigate("sharing") },
                        onFriends = { nav.navigate("profile/$id/friends") })
                }
                composable("profile/{id}/friends") { e ->
                    ProfileFriendsScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }, onProfile = { nav.navigate("profile/$it") })
                }
                composable("profile/{id}/{section}/{item}") { e ->
                    ProfileCardsScreen(e.arguments?.getString("id") ?: "", e.arguments?.getString("section") ?: "",
                        e.arguments?.getString("item")?.takeIf { it != "-" }, onBack = { nav.popBackStack() },
                        onCard = { nav.navigate("collection/card/$it?search=1") }, onList = { nav.navigate("collection/list/$it") },
                        onRankings = { nav.navigate("collection/list/$it/rankings") },
                        onFollowChanges = { k, id -> nav.navigate("collection/following/$k/$id") })
                }
                // Following (contract/follows-2026-10-25.md).
                composable("collection/following") {
                    FollowingScreen(onBack = { nav.popBackStack() }, onOpen = { nav.navigate(it) })
                }
                composable("collection/following/{kind}/{id}") { e ->
                    FollowChangesScreen(e.arguments?.getString("kind") ?: "", e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() },
                        onCard = { nav.navigate("collection/card/$it?search=1") })
                }
                // A share link (contract/share-links-2026-10-23.md).
                composable("collection/shared/{token}") { e ->
                    SharedLinkScreen(e.arguments?.getString("token") ?: "", onBack = { nav.popBackStack() },
                        onCard = { nav.navigate("collection/card/$it?search=1") }, onList = { nav.navigate("collection/list/$it") },
                        onFollowChanges = { k, id -> nav.navigate("collection/following/$k/$id") },
                        onRankings = { nav.navigate("collection/list/$it/rankings") })
                }
                composable("collection/matches") {
                    TradeMatchesScreen(onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/match/$it") },
                        onFriends = { nav.navigate("friends") }, onSharing = { nav.navigate("sharing") })
                }
                composable("collection/match/{id}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    TradeMatchScreen(id, onBack = { nav.popBackStack() }, onProfile = { nav.navigate("profile/$id") },
                        onCard = { nav.navigate("collection/card/$it?search=1") }, onTrade = { nav.navigate("collection/trade/$it") })
                }
                composable("collection") {
                    LibraryHomeScreen(foregrounds = foregrounds, go = { nav.navigate(it) })
                }
                composable("collection/binders") {
                    BindersScreen(onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/binder/$it") },
                        onCard = { nav.navigate("collection/card/$it") })
                }
                composable("collection/binder/{id}") { e ->
                    val id = e.arguments?.getString("id") ?: UNSORTED
                    BinderScreen(id, onBack = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it?binder=$id") })
                }
                composable("collection/wants") {
                    WantsScreen(onBack = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it?search=1") },
                        onBuy = { nav.navigate("collection/buy/$it") })
                }
                composable("collection/decks") {
                    ListsScreen(ListKind.Deck, onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/list/$it") },
                        onFind = { nav.navigate("collection/find") }, onImport = { nav.navigate("collection/import/deck") })
                }
                composable("collection/import/{kind}") { e ->
                    val kind = if (e.arguments?.getString("kind") == "cube") ListKind.Cube else ListKind.Deck
                    ListImportScreen(kind, onBack = { nav.popBackStack() }, onCreated = { id ->
                        nav.popBackStack()
                        nav.navigate("collection/list/$id")
                    })
                }
                composable("collection/find?job={job}", arguments = listOf(navArgument("job") { nullable = true })) { e ->
                    DeckFinderScreen(onBack = { nav.popBackStack() }, onCreated = { id ->
                        nav.popBackStack()
                        nav.navigate("collection/list/$id")
                    }, jobId = e.arguments?.getString("job"))
                }
                composable("collection/cubes") {
                    ListsScreen(ListKind.Cube, onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/list/$it") },
                        onImport = { nav.navigate("collection/import/cube") }, onRankings = { nav.navigate("collection/rankings") })
                }
                // Cube rankings (contract/cube-rankings-2026-10-21.md).
                composable("collection/rankings") {
                    RankingsScreen(null, onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/ranking/$it") },
                        onCube = { nav.navigate("collection/list/$it/rankings") })
                }
                composable("collection/list/{id}/rankings") { e ->
                    RankingsScreen(e.arguments?.getString("id"), onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/ranking/$it") })
                }
                composable("collection/ranking/{id}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    RankingScreen(id, onBack = { nav.popBackStack() }, go = { nav.navigate("collection/ranking/$id/$it") })
                }
                composable("collection/ranking/{id}/screen/{job}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    RankingPickScreen(id, RankJob.of(e.arguments?.getString("job") ?: "F") ?: RankJob.Final, onBack = { nav.popBackStack() },
                        go = { nav.navigate("collection/ranking/$id/$it") })
                }
                composable("collection/ranking/{id}/lists/{job}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    RankingListsScreen(id, RankJob.of(e.arguments?.getString("job") ?: "F") ?: RankJob.Final, onBack = { nav.popBackStack() },
                        go = { nav.navigate("collection/ranking/$id/$it") })
                }
                composable("collection/ranking/{id}/card/{card}/{job}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    RankingCardScreen(id, e.arguments?.getString("card") ?: "", RankJob.of(e.arguments?.getString("job") ?: "F") ?: RankJob.Final,
                        onBack = { nav.popBackStack() }, go = { nav.navigate("collection/ranking/$id/$it") })
                }
                composable("collection/ranking/{id}/compare/{other}/{job}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    RankingCompareScreen(id, e.arguments?.getString("other") ?: "", RankJob.of(e.arguments?.getString("job") ?: "F") ?: RankJob.Final,
                        onBack = { nav.popBackStack() }, go = { nav.navigate("collection/ranking/$id/$it") })
                }
                composable("collection/ranking/{id}/pack") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    RankingPackScreen(id, onBack = { nav.popBackStack() }, go = { nav.navigate("collection/ranking/$id/$it") })
                }
                composable("collection/ranking/{id}/changes") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    RankingChangesScreen(id, onBack = { nav.popBackStack() }, go = { nav.navigate("collection/ranking/$id/$it") })
                }
                composable("collection/list/{id}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    ListDetailScreen(id, onBack = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it?list=$id") },
                        onAdd = { nav.navigate("collection/list/$id/add") }, onVersions = { nav.navigate("collection/list/$id/versions") },
                        onOpen = { nav.navigate("collection/list/$it") },
                        onPrinting = { card, board, finish, lang, cond -> nav.navigate("collection/list/$id/printing/$card/$board/$finish/$lang/$cond") },
                        onStats = { nav.navigate("collection/list/$id/stats") }, onRankings = { nav.navigate("collection/list/$id/rankings") },
                        onSync = { nav.navigate("collection/list/$id/sync") },
                        onInsights = { f, a -> nav.navigate(site.table1.events.insights.InsightsRoutes.archetype(f, a)) },
                        onGuide = { nav.navigate("collection/list/$id/guide") },
                        onBuy = { nav.navigate("collection/buy/$id") })
                }
                // The Buy screen (contract/buy-2026-11-06.md): a deck or cube id, "wants" or "missing".
                composable("collection/buy/{source}") { e ->
                    BuyScreen(e.arguments?.getString("source") ?: "wants", onBack = { nav.popBackStack() },
                        onCard = { nav.navigate("collection/card/$it?search=1") })
                }
                // A deck's sideboard guide (contract/sideboard-guide-2026-11-04.md).
                composable("collection/list/{id}/guide") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    SideboardGuideScreen(id, onBack = { nav.popBackStack() }, go = { nav.navigate("collection/list/$id/guide/$it") })
                }
                composable("collection/list/{id}/guide/new") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    NewMatchupScreen(id, onBack = { nav.popBackStack() }, onCreated = { m ->
                        nav.navigate("collection/list/$id/guide/m/$m") { popUpTo("collection/list/{id}/guide/new") { inclusive = true } }
                    })
                }
                composable("collection/list/{id}/guide/print") { e -> SideboardPrintScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/guide/pool") { e -> SideboardPoolScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/guide/m/{m}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    val m = e.arguments?.getString("m") ?: ""
                    SideboardMatchupScreen(id, m, onBack = { nav.popBackStack() },
                        onPick = { side -> nav.navigate("collection/list/$id/guide/m/$m/${if (side == GuideSide.In) "in" else "out"}") })
                }
                composable("collection/list/{id}/guide/m/{m}/{side}") { e ->
                    SideboardPickScreen(e.arguments?.getString("id") ?: "", e.arguments?.getString("m") ?: "",
                        if (e.arguments?.getString("side") == "out") GuideSide.Out else GuideSide.In, onBack = { nav.popBackStack() })
                }
                composable("collection/list/{id}/sync") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    CubeSyncScreen(id, onBack = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it?list=$id") })
                }
                composable("collection/list/{id}/stats") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    ListStatsScreen(id, onBack = { nav.popBackStack() }, onHand = { nav.navigate("collection/list/$id/stats/hand") },
                        onOdds = { nav.navigate("collection/list/$id/stats/odds") }, onPack = { nav.navigate("collection/list/$id/stats/pack") },
                        onCard = { nav.navigate("collection/card/$it") })
                }
                composable("collection/list/{id}/stats/hand") { e -> SampleHandScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/stats/odds") { e -> DrawOddsScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/stats/pack") { e -> SamplePackScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/printing/{card}/{board}/{finish}/{lang}/{cond}") { e ->
                    val a = e.arguments
                    ChangePrintingScreen(PrintingTarget.ListLine(a?.getString("id") ?: "", a?.getString("card") ?: "", a?.getString("board") ?: "main",
                        a?.getString("finish") ?: "nonfoil", a?.getString("lang") ?: "en", a?.getString("cond") ?: "NM"), onClose = { nav.popBackStack() })
                }
                composable("collection/list/{id}/add") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    ListAddScreen(id, onDone = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it?list=$id") })
                }
                composable("collection/list/{id}/versions") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    ListVersionsScreen(id, onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/list/$id/v/$it") })
                }
                composable("collection/list/{id}/v/{n}") { e ->
                    ListVersionScreen(e.arguments?.getString("id") ?: "", e.arguments?.getString("n")?.toIntOrNull() ?: 0,
                        onBack = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it?list=${e.arguments?.getString("id") ?: ""}") })
                }
                composable("collection/trades") {
                    TradesScreen(onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/trade/${it ?: "new"}") },
                        onMatch = { nav.navigate("collection/match/$it") }, onMatches = { nav.navigate("collection/matches") })
                }
                composable("collection/trade/{id}") { e ->
                    val id = e.arguments?.getString("id")?.takeIf { it != "new" }
                    TradeScreen(id, onBack = { nav.popBackStack() })
                }
                composable("collection/all") {
                    AllCardsScreen(
                        onBack = { nav.popBackStack() },
                        onOpen = { nav.navigate("collection/card/$it") },
                        onAdd = { nav.navigate("collection/add") },
                    )
                }
                composable("collection/csv") {
                    CollectionImportScreen(onBack = { nav.popBackStack() }, onAllCards = { nav.navigate("collection/all") })
                }
                composable("collection/add") {
                    AddCardsScreen(onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/card/$it") })
                }
                // The Scan cards tile and shortcut: Add cards with the scanner already up.
                composable("collection/add/scan") {
                    AddCardsScreen(onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/card/$it") }, scanFirst = true)
                }
                composable("collection/search") {
                    AddCardsScreen(onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/card/$it") }, search = true,
                        go = { nav.navigate(it) })
                }
                // Opened from a deck/cube (?list=) or a binder (?binder=): that list's lines or binder's copies come first.
                // ?search=1: wants, Missing, a friend's or shared card (contract/card-detail-2026-10-23.md § Scope).
                composable("collection/card/{id}?list={list}&binder={binder}&search={search}",
                    arguments = listOf(navArgument("list") { nullable = true }, navArgument("binder") { nullable = true },
                        navArgument("search") { nullable = true })) { e ->
                    val list = e.arguments?.getString("list")
                    val binder = e.arguments?.getString("binder")
                    val search = e.arguments?.getString("search") != null
                    CardDetailScreen(oracleId = e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() },
                        context = list?.let { CardContext.InList(it) } ?: binder?.let { CardContext.InBinder(it) } ?: if (search) CardContext.Search else null,
                        onList = { nav.navigate("collection/list/$it") })
                }
                composable("create") {
                    CreateEventScreen(
                        // Straight to inviting people; Back lands on the new event.
                        onCreated = { id ->
                            nav.navigate("event/$id") { popUpTo("events") }
                            nav.navigate("add/$id")
                        },
                        onCancel = { nav.popBackStack() },
                    )
                }
                composable("event/{id}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    EventScreen(
                        eventId = id, onBack = { nav.popBackStack() }, onAddPlayers = { nav.navigate("add/$id") },
                        onOpenTracker = { matchId -> nav.navigate("tracker/$matchId") },
                        onOpenPhotos = { nav.navigate("photos/$id") },
                        onOpenRedraft = { nav.navigate("redraft/$id") },
                        onOpenList = { nav.navigate("collection/list/$it") },
                    )
                }
                composable("redraft/{id}") { e ->
                    site.table1.events.ui.screens.RedraftScreen(eventId = e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() })
                }
                composable("eventpage/{id}?signup={signup}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    EventPageScreen(id, signUpNow = e.arguments?.getString("signup") == "true", onBack = { nav.popBackStack() },
                        onOpenEvent = { nav.navigate("event/$it") })
                }
                composable("photos/{id}") { e ->
                    DeckPhotosScreen(eventId = e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() })
                }
                composable("add/{id}") { e ->
                    AddPlayersScreen(eventId = e.arguments?.getString("id") ?: "", onDone = { nav.popBackStack() })
                }
                // Life tracker: full screen, no tab bar. No match id = local session on this device.
                composable("tracker") {
                    LifeTrackerScreen(matchId = null, onClose = { nav.popBackStack() })
                }
                composable("tracker/{matchId}") { e ->
                    LifeTrackerScreen(matchId = e.arguments?.getString("matchId"), onClose = { nav.popBackStack() })
                }
                composable("nearby") {
                    NearbyScreen(onJoined = { id -> nav.navigate("event/$id") { popUpTo("events") } }, onOpen = { id -> nav.navigate("event/$id") },
                        onBack = { nav.popBackStack() })
                }
            }
            }
        }
        if (topLevel) {
            T1TabBar(
                tabs = listOf(
                    T1Tab("events", "Events", T1Icon.TabEvents),
                    T1Tab("collection", "Collection", T1Icon.TabCollection),
                    T1Tab("insights", "Insights", T1Icon.TabInsights),
                    T1Tab("account", "Account", T1Icon.TabAccount),
                ),
                selected = route,
                onSelect = {
                    // The Library home syncs the collection itself each time it opens.
                    if (it == "collection") CatalogStore.load(userInitiated = true)
                    tab(it)
                },
            )
        }
    }
}

/** A sign-up link opened signed out: its event, shown over sign-in; signing in signs you up. */
object PendingSignUp {
    var page by androidx.compose.runtime.mutableStateOf<site.table1.events.data.EventPage?>(null)
}
