package site.table1.events.library

import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import site.table1.events.T1App
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.util.Telemetry

/* Sort (the View menu on every card list, after Group by; contract/card-sort-2026-10-25.md). One rule everywhere,
   tested against testdata/card-sort/cases.json (iOS CardSort.swift, web cardSort.ts):
   - Name: A–Z, ignoring case.
   - Mana value: spells low to high, then lands (Group by's Lands), then by name.
   - Set: newest set first, then set code, then collector number (digits as a number, then the text), then name; a
     card newer than the local card data goes last.
   Screens that had their own order keep it first: All cards' Recent and Price, binders' Most copies. Group by makes
   the sections; Sort orders the cards inside each. */

enum class CardSort(val wire: String, val title: String) {
    Recent("recent", "Most recent first"), Price("price", "Highest price first"), Count("count", "Most copies first"),
    Name("name", "Sort by name"), ManaValue("manaValue", "Sort by mana value"), Set("set", "Sort by set");

    /** Whether this rule orders the cards (name, mana value, set); the others are the screen's own. */
    val shared: Boolean get() = this == Name || this == ManaValue || this == Set

    /** `items` in this sort, each item's key worked out once. Recent, price and count leave the order as it is. */
    fun <T> apply(items: List<T>, key: (T) -> SortKey): List<T> {
        if (!shared) return items
        return items.map { key(it) to it }.sortedWith { a, b -> SortKey.compare(a.first, b.first, this) }.map { it.second }
    }

    /** The screen family's choices, its own order first (that's also where it starts). */
    enum class Screen { List, Shared, Binder, AllCards }

    companion object {
        fun options(s: Screen): List<CardSort> = when (s) {
            Screen.List, Screen.Shared -> listOf(Name, ManaValue, Set)
            Screen.Binder -> listOf(Count, Name, ManaValue, Set)
            Screen.AllCards -> listOf(Recent, Price, Name, ManaValue, Set)
        }

        /** The saved sort, or the screen's first option when it's missing or not one of its own. */
        fun of(wire: String?, s: Screen): CardSort = options(s).let { o -> o.firstOrNull { it.wire == wire } ?: o[0] }
    }
}

/** What a card sorts on: its name, its mana value (and whether it's a land) and the printing shown. */
class SortKey(name: String, val cmc: Double = 0.0, val land: Boolean = false, val released: String = "", val set: String = "", val cn: String = "") {
    val name = name.lowercase()
    private val number: Int = cn.filter { it.isDigit() }.toIntOrNull() ?: Int.MAX_VALUE

    companion object {
        fun of(name: String, keys: GroupKeys?, printing: CatalogPrinting?) =
            SortKey(name, keys?.cmc ?: 0.0, keys?.manaValue == "Lands", printing?.releasedAt ?: "", printing?.set ?: "", printing?.cn ?: "")

        /** Negative when `a` goes before `b` under `by` (name, mana value or set; any other sort reads as name). */
        fun compare(a: SortKey, b: SortKey, by: CardSort): Int {
            when (by) {
                CardSort.ManaValue -> {
                    if (a.land != b.land) return if (a.land) 1 else -1
                    if (a.cmc != b.cmc) return a.cmc.compareTo(b.cmc)
                }
                CardSort.Set -> {
                    if (a.set.isEmpty() != b.set.isEmpty()) return if (a.set.isEmpty()) 1 else -1
                    if (a.released != b.released) return b.released.compareTo(a.released)
                    if (a.set != b.set) return a.set.compareTo(b.set)
                    if (a.number != b.number) return a.number.compareTo(b.number)
                    if (a.cn != b.cn) return a.cn.compareTo(b.cn)
                }
                else -> {}
            }
            return a.name.compareTo(b.name)
        }
    }
}

/** Saved Sort keys in the `library` prefs: decks and cubes share one per kind between your own and shared ones;
 *  All cards, binders and shared sections each keep their own. */
object SortPref {
    const val DECK = "deck.sort"
    const val CUBE = "cube.sort"
    const val ALL_CARDS = "allCards.sortBy"
    const val BINDER = "binder.sort"
    const val SHARED = "shared.sort"
}

/** The Sort saved under `library` prefs `key`. All cards' older 0/1/2 setting (recent / price / set) carries over. */
@Composable
fun rememberCardSort(key: String, screen: CardSort.Screen): MutableState<CardSort> {
    val prefs = remember { T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE) }
    val state = remember(key) {
        val old = if (key == SortPref.ALL_CARDS && !prefs.contains(key)) listOf("recent", "price", "set").getOrNull(prefs.getInt("allCards.sort", 0)) else null
        mutableStateOf(CardSort.of(prefs.getString(key, null) ?: old, screen))
    }
    return remember(state) {
        object : MutableState<CardSort> by state {
            override var value: CardSort
                get() = state.value
                set(v) { state.value = v; prefs.edit().putString(key, v.wire).apply() }
        }
    }
}

/** A deck's or cube's Sort, shared between your own and the ones shared with you (both start on Name). */
@Composable
fun rememberListSort(kind: ListKind?): MutableState<CardSort> =
    rememberCardSort(if (kind == ListKind.Cube) SortPref.CUBE else SortPref.DECK, CardSort.Screen.List)

/** Sort's items for the View menu, the current one selected. */
fun sortMenuItems(sort: MutableState<CardSort>, screen: CardSort.Screen, name: String): List<T1MenuItem> =
    CardSort.options(screen).map { o ->
        T1MenuItem(o.title, selected = o == sort.value) {
            if (o != sort.value) {
                sort.value = o
                Telemetry.capture("card_sort_changed", mapOf("sort" to o.wire, "screen" to name))
            }
        }
    }
