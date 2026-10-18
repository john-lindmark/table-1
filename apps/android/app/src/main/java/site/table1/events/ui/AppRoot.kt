package site.table1.events.ui

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
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.status.SessionStatus
import site.table1.events.T1App
import site.table1.events.data.JoinLink
import site.table1.events.data.Repo
import site.table1.events.library.AddCardsScreen
import site.table1.events.library.AllCardsScreen
import site.table1.events.library.CardDetailScreen
import site.table1.events.library.CatalogStore
import site.table1.events.library.CollectionStore
import site.table1.events.library.DeckFinderScreen
import site.table1.events.library.LibraryHomeScreen
import site.table1.events.library.BindersStore
import site.table1.events.library.BindersScreen
import site.table1.events.library.BinderScreen
import site.table1.events.library.WantsScreen
import site.table1.events.library.UNSORTED
import site.table1.events.library.CollectionImportScreen
import site.table1.events.library.TradeScreen
import site.table1.events.library.TradesScreen
import site.table1.events.library.TradesStore
import site.table1.events.library.LinePrintingScreen
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
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Tab
import site.table1.events.ui.components.T1TabBar
import site.table1.events.ui.screens.AccountScreen
import site.table1.events.ui.screens.AddPlayersScreen
import site.table1.events.ui.screens.CreateEventScreen
import site.table1.events.ui.screens.EventScreen
import site.table1.events.ui.screens.EventsHomeScreen
import site.table1.events.ui.screens.NearbyScreen
import site.table1.events.auth.SignIn
import site.table1.events.ui.screens.NameScreen
import site.table1.events.ui.screens.SignInScreen
import site.table1.events.ui.tracker.LifeTrackerScreen

/**
 * Signed out → sign-in. Signed in → tabs Events | Collection (the Library) | Account. A QR join link that arrived before
 * sign-in (camera scan, notification) is held and completed right after.
 */
@Composable
fun AppRoot(pendingJoin: JoinLink?, onJoinConsumed: () -> Unit) {
    val status by T1App.supabase.auth.sessionStatus.collectAsState()
    when (status) {
        is SessionStatus.Authenticated ->
            if (SignIn.needsName((status as SessionStatus.Authenticated).session.user)) NameScreen()
            else SignedInApp(pendingJoin, onJoinConsumed)
        is SessionStatus.Initializing -> T1Screen { Bar("Table 1") }
        else -> SignInScreen()
    }
}

@Composable
private fun SignedInApp(pendingJoin: JoinLink?, onJoinConsumed: () -> Unit) {
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
        }
        CatalogStore.load(userInitiated = false)
    }
    DisposableEffect(Unit) { onDispose { CollectionStore.stop(); ListsStore.stop(); TradesStore.stop(); BindersStore.stop() } }
    LaunchedEffect(foregrounds) { CatalogStore.load(userInitiated = route?.startsWith("collection") == true) }

    val topLevel = route == "events" || route == "account" || route == "collection"
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
                composable("account") { AccountScreen(foregrounds = foregrounds) }
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
                    )
                }
                composable("collection/binders") {
                    BindersScreen(onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/binder/$it") })
                }
                composable("collection/binder/{id}") { e ->
                    BinderScreen(e.arguments?.getString("id") ?: UNSORTED, onBack = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it") })
                }
                composable("collection/wants") {
                    WantsScreen(onBack = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it") })
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
                        onImport = { nav.navigate("collection/import/cube") })
                }
                composable("collection/list/{id}") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    ListDetailScreen(id, onBack = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it") },
                        onAdd = { nav.navigate("collection/list/$id/add") }, onVersions = { nav.navigate("collection/list/$id/versions") },
                        onOpen = { nav.navigate("collection/list/$it") },
                        onPrinting = { card, board, finish -> nav.navigate("collection/list/$id/printing/$card/$board/$finish") },
                        onStats = { nav.navigate("collection/list/$id/stats") })
                }
                composable("collection/list/{id}/stats") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    ListStatsScreen(id, onBack = { nav.popBackStack() }, onHand = { nav.navigate("collection/list/$id/stats/hand") },
                        onOdds = { nav.navigate("collection/list/$id/stats/odds") }, onPack = { nav.navigate("collection/list/$id/stats/pack") })
                }
                composable("collection/list/{id}/stats/hand") { e -> SampleHandScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/stats/odds") { e -> DrawOddsScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/stats/pack") { e -> SamplePackScreen(e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() }) }
                composable("collection/list/{id}/printing/{card}/{board}/{finish}") { e ->
                    val a = e.arguments
                    LinePrintingScreen(a?.getString("id") ?: "", a?.getString("card") ?: "", a?.getString("board") ?: "main",
                        a?.getString("finish") ?: "nonfoil", onDone = { nav.popBackStack() })
                }
                composable("collection/list/{id}/add") { e ->
                    ListAddScreen(e.arguments?.getString("id") ?: "", onDone = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it") })
                }
                composable("collection/list/{id}/versions") { e ->
                    val id = e.arguments?.getString("id") ?: ""
                    ListVersionsScreen(id, onBack = { nav.popBackStack() }, onOpen = { nav.navigate("collection/list/$id/v/$it") })
                }
                composable("collection/list/{id}/v/{n}") { e ->
                    ListVersionScreen(e.arguments?.getString("id") ?: "", e.arguments?.getString("n")?.toIntOrNull() ?: 0,
                        onBack = { nav.popBackStack() }, onCard = { nav.navigate("collection/card/$it") })
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
                composable("collection/card/{id}") { e ->
                    CardDetailScreen(oracleId = e.arguments?.getString("id") ?: "", onBack = { nav.popBackStack() })
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
                    )
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
