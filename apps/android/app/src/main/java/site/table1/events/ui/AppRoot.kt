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
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import site.table1.events.T1App
import site.table1.events.data.JoinLink
import site.table1.events.data.WebLink
import site.table1.events.openInBrowser
import site.table1.events.data.Repo
import site.table1.events.library.RankingsScreen
import site.table1.events.library.SharedLinkScreen
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
import site.table1.events.ui.screens.EventsHomeScreen
import site.table1.events.ui.screens.NearbyScreen
import site.table1.events.auth.EmailSignIn
import site.table1.events.auth.SignIn
import site.table1.events.ui.screens.NameScreen
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
    // Signed in any way: the email code step kept for a return is done with.
    val signedIn = status is SessionStatus.Authenticated
    LaunchedEffect(signedIn) { if (signedIn) EmailSignIn.clear() }
    when (status) {
        is SessionStatus.Authenticated ->
            if (SignIn.needsName((status as SessionStatus.Authenticated).session.user)) NameScreen(pendingJoin)
            else SignedInApp(pendingJoin, onJoinConsumed, pendingLink, onLinkConsumed)
        is SessionStatus.Initializing -> T1Screen { Bar("Table 1") }
        else -> {
            // Standings tapped while the app was still starting: read them on the web rather than signing in first.
            val context = LocalContext.current
            LaunchedEffect(pendingLink) {
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
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) {
                if (started) autoOpenArmed = true
                started = true
                foregrounds++
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
            is WebLink.Tracker -> show("events", listOf(link.matchId?.let { "tracker/$it" } ?: "tracker"))
            is WebLink.JoinCode -> runCatching { Repo.joinByCode(link.code) }
                .onSuccess { show("events", listOf("event/${it.eventId}")) }
                .onFailure { joinError = it.message; show("events", emptyList()) }
            // The event screen has the standings for its organizer and players; anyone else gets the public page.
            is WebLink.Standings ->
                if (Repo.eventAccess(link.eventId) in setOf("organizer", "player")) show("events", listOf("event/${link.eventId}"))
                else openInBrowser(context, Uri.parse(WebLink.standingsUrl(link.eventId)))
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
        if (userId != null) {
            CollectionStore.start(userId)
            ListsStore.start(userId)
            BindersStore.start(userId)
            HeroesStore.start(userId)
        }
        CatalogStore.load(userInitiated = false)
    }
    DisposableEffect(Unit) { onDispose { CollectionStore.stop(); ListsStore.stop(); TradesStore.stop(); BindersStore.stop(); HeroesStore.stop(); FriendsStore.stop() } }
    LaunchedEffect(foregrounds) {
        CatalogStore.load(userInitiated = route?.startsWith("collection") == true)
        if (foregrounds > 0) HeroesStore.refresh()
    }

    val topLevel = route == "events" || route == "account" || route == "collection" || route == "insights"
    // Review (proposed archetypes and bans) shows for moderators; the server refuses anyone else.
    var moderator by remember { mutableStateOf(false) }
    LaunchedEffect(userId) {
        moderator = runCatching {
            Json.parseToJsonElement(T1App.supabase.postgrest.rpc("moderation_me").data).jsonObject["moderator"]?.jsonPrimitive?.booleanOrNull == true
        }.getOrDefault(false)
    }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).let { if (topLevel) it.consumeWindowInsets(WindowInsets.navigationBars) else it }) {
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
                        onProfile = { nav.navigate("profile/$it") })
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
                        onMatch = { nav.navigate("collection/match/$id") }, onSharing = { nav.navigate("sharing") })
                }
                composable("profile/{id}/{section}/{item}") { e ->
                    ProfileCardsScreen(e.arguments?.getString("id") ?: "", e.arguments?.getString("section") ?: "",
                        e.arguments?.getString("item")?.takeIf { it != "-" }, onBack = { nav.popBackStack() },
                        onCard = { nav.navigate("collection/card/$it?search=1") }, onList = { nav.navigate("collection/list/$it") },
                        onRankings = { nav.navigate("collection/list/$it/rankings") })
                }
                // A share link (contract/share-links-2026-10-23.md).
                composable("collection/shared/{token}") { e ->
                    SharedLinkScreen(e.arguments?.getString("token") ?: "", onBack = { nav.popBackStack() },
                        onCard = { nav.navigate("collection/card/$it?search=1") }, onList = { nav.navigate("collection/list/$it") })
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
                    LibraryHomeScreen(
                        foregrounds = foregrounds,
                        onAllCards = { nav.navigate("collection/all") },
                        onAdd = { nav.navigate("collection/add") },
                        onImportExport = { nav.navigate("collection/csv") },
                        onDecks = { nav.navigate("collection/decks") },
                        onCubes = { nav.navigate("collection/cubes") },
                        onTrades = { nav.navigate("collection/trades") },
                        onBinders = { nav.navigate("collection/binders") },
                        onWants = { nav.navigate("collection/wants") },
                        onMatches = { nav.navigate("collection/matches") },
                    )
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
                    WantsScreen(onBack = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it?search=1") })
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
                composable("collection/find") {
                    DeckFinderScreen(onBack = { nav.popBackStack() }, onCreated = { id ->
                        nav.popBackStack()
                        nav.navigate("collection/list/$id")
                    })
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
                        onPrinting = { card, board, finish, lang -> nav.navigate("collection/list/$id/printing/$card/$board/$finish/$lang") },
                        onStats = { nav.navigate("collection/list/$id/stats") }, onRankings = { nav.navigate("collection/list/$id/rankings") })
                }
                composable("collection/list/{id}/stats") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    ListStatsScreen(id, onBack = { nav.popBackStack() }, onHand = { nav.navigate("collection/list/$id/stats/hand") },
                        onOdds = { nav.navigate("collection/list/$id/stats/odds") }, onPack = { nav.navigate("collection/list/$id/stats/pack") })
                }
                composable("collection/list/{id}/stats/hand") { e -> SampleHandScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/stats/odds") { e -> DrawOddsScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/stats/pack") { e -> SamplePackScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/printing/{card}/{board}/{finish}/{lang}") { e ->
                    val a = e.arguments
                    ChangePrintingScreen(PrintingTarget.ListLine(a?.getString("id") ?: "", a?.getString("card") ?: "", a?.getString("board") ?: "main",
                        a?.getString("finish") ?: "nonfoil", a?.getString("lang") ?: "en"), onClose = { nav.popBackStack() })
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
                    TradesScreen(onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/trade/${it ?: "new"}") })
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
                    )
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
        if (topLevel) {
            T1TabBar(
                tabs = listOf(
                    T1Tab("events", "Events", listOf(0 to 0, 1 to 0, 0 to 1, 1 to 1)),
                    T1Tab("collection", "Collection", listOf(0 to 0, 0 to 1, 1 to 1)),
                    T1Tab("insights", "Insights", listOf(0 to 1, 1 to 0, 1 to 1)),
                    T1Tab("account", "Account", listOf(0 to 0, 1 to 0, 1 to 1)),
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
