package site.table1.events.ui

import android.content.Context
import androidx.compose.runtime.mutableStateMapOf
import site.table1.events.T1App
import site.table1.events.util.Telemetry

/**
 * The main navigation (contract/main-nav-2026-11-14.md): four tabs, each with sub-tabs in a strip above the tab bar.
 * Plain data and rules, so unit tests run without Android (MainNavTest, against testdata/main-nav/cases.json).
 */
object MainNav {
    data class Sub(val id: String, val label: String, val fullScreen: Boolean = false)
    data class Tab(val id: String, val label: String, val default: String, val subs: List<Sub>)

    val tabs = listOf(
        Tab("events", "Play", "events", listOf(Sub("events", "Events"), Sub("tracker", "Life tracker", fullScreen = true))),
        Tab("collection", "Cards", "collection", listOf(Sub("collection", "Collection"), Sub("trade", "Trade"), Sub("wants", "Wants"))),
        Tab("insights", "Insights", "constructed", listOf(Sub("constructed", "Constructed"), Sub("limited", "Limited"), Sub("rankings", "Rankings"))),
        Tab("account", "Account", "profile", listOf(Sub("profile", "Profile"), Sub("records", "Records"), Sub("settings", "Settings"))),
    )

    fun tab(id: String): Tab? = tabs.firstOrNull { it.id == id }

    /** What a tab opens on for its stored sub-tab: the stored one when it's one of the tab's places, else the default.
     *  A full-screen sub-tab (Life tracker) isn't a place and is never remembered. */
    fun remembered(tab: String, stored: String?): String {
        val t = tab(tab) ?: return stored ?: ""
        return t.subs.firstOrNull { it.id == stored && !it.fullScreen }?.id ?: t.default
    }

    /** The prefs key a tab's sub-tab is kept under. */
    fun key(tab: String) = "nav.sub.$tab"

    /** A sub-tab root's own route on the Collection graph, which a link or push selects instead of pushing a copy. */
    private val roots = mapOf(
        "collection/trades" to ("collection" to "trade"),
        "collection/wants" to ("collection" to "wants"),
        "collection/rankings" to ("insights" to "rankings"),
    )

    /** Where a link's or push's screens land: the tab, the sub-tab to select (null: leave it as it is) and the screens
     *  to push on top. A stack through a sub-tab root (Trades, Wants, every ranking of yours) selects that sub-tab and
     *  pushes only what was above it; an empty stack selects the tab's first sub-tab, as the web's `/`, `/library`, `/me`. */
    data class Placed(val tab: String, val sub: String?, val stack: List<String>)

    fun place(tab: String, stack: List<String>): Placed {
        val i = stack.indexOfLast { it in roots }
        if (i >= 0) {
            val (t, s) = roots.getValue(stack[i])
            return Placed(t, s, stack.drop(i + 1))
        }
        if (stack.isEmpty()) return Placed(tab, tab(tab)?.subs?.firstOrNull()?.id?.takeIf { tab != "insights" }, stack)
        return Placed(tab, null, stack)
    }
}

/**
 * Which sub-tab each tab is on, kept in prefs `nav.sub.<tab>` across launches. Insights' Constructed / Limited is
 * InsightsStore.section (it follows the account); only Rankings is held here on its own.
 */
object MainNavState {
    private val prefs get() = T1App.instance.getSharedPreferences("nav", Context.MODE_PRIVATE)
    private fun stored(tab: String): String? = runCatching { prefs.getString(MainNav.key(tab), null) }.getOrNull()

    /** Read once, before anything draws, so reading a tab's sub-tab never writes state during composition. */
    private val subs = mutableStateMapOf<String, String>().apply { MainNav.tabs.forEach { put(it.id, MainNav.remembered(it.id, stored(it.id))) } }

    /** The sub-tab [tab] is on now. */
    fun current(tab: String): String = subs[tab] ?: MainNav.remembered(tab, null)

    /** Debug only: the tab (and sub-tab) `--es t1MainNav` opens signed out; null when not asked for. */
    var demoTab: String? = null; private set
    fun demo(arg: String) {
        val tab = arg.substringBefore(":")
        if (MainNav.tab(tab) == null) return
        demoTab = tab
        arg.substringAfter(":", "").takeIf { it.isNotEmpty() }?.let { select(tab, it, how = "demo") }
    }

    /** Insights' sub-tab as drawn: Rankings when that's where it was left, else the section Insights keeps. */
    fun insights(section: String): String = if (current("insights") == "rankings") "rankings" else if (section == "limited") "limited" else "constructed"

    /** Selects [sub] on [tab] and keeps it. Full-screen sub-tabs aren't places: they're not kept. */
    fun select(tab: String, sub: String, how: String = "tap") {
        val t = MainNav.tab(tab) ?: return
        val s = t.subs.firstOrNull { it.id == sub } ?: return
        if (how == "tap") Telemetry.capture("nav_sub_tab", mapOf("tab" to tab, "sub" to sub))
        if (s.fullScreen) return
        if (tab == "insights" && sub != "rankings") site.table1.events.insights.InsightsStore.let {
            if (it.section != sub) it.pickSection(sub)
        }
        subs[tab] = sub
        runCatching { prefs.edit().putString(MainNav.key(tab), sub).apply() }
    }
}
