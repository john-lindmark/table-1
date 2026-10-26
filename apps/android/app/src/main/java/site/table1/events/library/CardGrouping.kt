package site.table1.events.library

import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import site.table1.events.T1App
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.util.Telemetry

/* Group by (the View menu on every card list: your decks, cubes, binders and All cards, and anything shared with you
   on a profile; contract/shared-lists-grouping-2026-10-20.md §4). One rule everywhere, tested against
   testdata/card-grouping/cases.json (iOS CardGrouping.swift, web cardGrouping.ts):
   - Type: Creatures, Planeswalkers, Instants, Sorceries, Artifacts, Enchantments, Battles, Lands, Other (the front
     face's type line; a land creature is a creature).
   - Color: White, Blue, Black, Red, Green, Multicolor, Colorless, then Lands (from the card's colors; packs without
     colors fall back to the mana cost's symbols).
   - Mana value: 0 … 6, 7+, then Lands (lands have mana value 0 but read as their own pile).
   Decks start on Type, cubes on Color, collections and binders on None. */

enum class CardGrouping(val wire: String, val title: String) {
    None("none", "No groups"), Type("type", "Group by type"), Color("color", "Group by color"), ManaValue("manaValue", "Group by mana value");

    val order: List<String>
        get() = when (this) {
            None -> emptyList()
            Type -> TYPE_ORDER
            Color -> COLOR_ORDER
            ManaValue -> MV_ORDER
        }

    /** The group's heading: mana values read "Mana value 3". */
    fun label(key: String) = if (this == ManaValue && key != "Lands") "Mana value $key" else key

    /** Keys in this grouping's order (unknown ones last, by name). */
    fun sorted(keys: Iterable<String>): List<String> =
        keys.distinct().sortedWith(compareBy<String>({ order.indexOf(it).let { i -> if (i < 0) 99 else i } }, { it }))

    companion object {
        val TYPE_ORDER = listOf("Creatures", "Planeswalkers", "Instants", "Sorceries", "Artifacts", "Enchantments", "Battles", "Lands", "Other")
        val COLOR_ORDER = listOf("White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands")
        val MV_ORDER = listOf("0", "1", "2", "3", "4", "5", "6", "7+", "Lands")

        /** A deck's or cube's choices (they always group); collections and binders add None. */
        fun options(list: Boolean): List<CardGrouping> = if (list) listOf(Type, Color, ManaValue) else entries

        fun parse(wire: String?): CardGrouping? = entries.firstOrNull { it.wire == wire }

        fun typeGroup(t: String) = when {
            "Creature" in t -> "Creatures"
            "Planeswalker" in t -> "Planeswalkers"
            "Land" in t -> "Lands"
            "Instant" in t -> "Instants"
            "Sorcery" in t -> "Sorceries"
            "Artifact" in t -> "Artifacts"
            "Enchantment" in t -> "Enchantments"
            "Battle" in t -> "Battles"
            else -> "Other"
        }

        fun colorGroup(letters: String): String {
            val colors = listOf('W' to "White", 'U' to "Blue", 'B' to "Black", 'R' to "Red", 'G' to "Green").filter { letters.contains(it.first) }
            return if (colors.size > 1) "Multicolor" else colors.firstOrNull()?.second ?: "Colorless"
        }
    }
}

/** One card's group under each grouping, worked out once from its Oracle card. */
data class GroupKeys(val type: String = "Other", val color: String = "Colorless", val manaValue: String = "0",
                     /** The mana value itself, for Sort by mana value. */
                     val cmc: Double = 0.0) {
    operator fun get(g: CardGrouping): String = when (g) {
        CardGrouping.None -> ""
        CardGrouping.Type -> type
        CardGrouping.Color -> color
        CardGrouping.ManaValue -> manaValue
    }

    companion object {
        fun of(typeLine: String, manaCost: String, colors: String, cmc: Double): GroupKeys {
            val front = typeLine.substringBefore(" // ")
            val type = CardGrouping.typeGroup(front)
            if ("Land" in front && "Creature" !in front) return GroupKeys(type, "Lands", "Lands", cmc)
            val mv = kotlin.math.floor(cmc).toInt()
            return GroupKeys(type, CardGrouping.colorGroup(colors.ifEmpty { manaCost }), if (mv >= 7) "7+" else "${maxOf(0, mv)}", cmc)
        }

        fun of(o: CatalogOracle?): GroupKeys = o?.let { of(it.typeLine, it.manaCost, it.colors, it.cmc) } ?: GroupKeys()

        /** Each card group's keys, by card group id, from the cards' cover printings. */
        fun forGroups(groups: List<CardGroup>, db: CatalogDb): Map<String, GroupKeys> {
            val oracles = db.oracles(groups.mapNotNull { it.cover?.oracleIdx }.toSet())
            return groups.associate { g -> g.id to of(g.cover?.let { oracles[it.oracleIdx] }) }
        }
    }
}

/** Items in sections under `by`, the screen's own order kept inside each: one untitled section for None. */
fun <T> groupSections(items: List<T>, by: CardGrouping, keys: (T) -> GroupKeys?): List<Pair<String, List<T>>> {
    if (by == CardGrouping.None) return listOf("" to items)
    val byKey = items.groupBy { keys(it)?.get(by) ?: "Other" }
    return by.sorted(byKey.keys).map { it to byKey.getValue(it) }
}

/** Saved Group by keys in the `library` prefs: decks and cubes share one per kind between your own and shared ones;
 *  All cards, binders and shared sections each keep their own. */
object GroupingKey {
    const val DECK = "deck.grouping"
    const val CUBE = "cube.grouping"
    const val ALL_CARDS = "allCards.grouping"
    const val BINDER = "binder.grouping"
    const val SHARED = "shared.grouping"
}

/** The Group by saved under `library` prefs `key`. */
@Composable
fun rememberCardGrouping(key: String, default: CardGrouping, list: Boolean): MutableState<CardGrouping> {
    val prefs = remember { T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE) }
    val state = remember(key) {
        mutableStateOf(CardGrouping.parse(prefs.getString(key, null))?.takeIf { it in CardGrouping.options(list) } ?: default)
    }
    return remember(state) {
        object : MutableState<CardGrouping> by state {
            override var value: CardGrouping
                get() = state.value
                set(v) { state.value = v; prefs.edit().putString(key, v.wire).apply() }
        }
    }
}

/** A deck's or cube's Group by (Type for decks, Color for cubes), shared between your own and the ones shared with you. */
@Composable
fun rememberListGrouping(kind: ListKind?): MutableState<CardGrouping> =
    if (kind == ListKind.Cube) rememberCardGrouping(GroupingKey.CUBE, CardGrouping.Color, true)
    else rememberCardGrouping(GroupingKey.DECK, CardGrouping.Type, true)

/** Group by's items for the View menu, the current one selected. */
fun groupingMenuItems(grouping: MutableState<CardGrouping>, list: Boolean, screen: String): List<T1MenuItem> =
    CardGrouping.options(list).map { g ->
        T1MenuItem(g.title, selected = g == grouping.value) {
            if (g != grouping.value) {
                grouping.value = g
                Telemetry.capture("card_grouping_changed", mapOf("grouping" to g.wire, "screen" to screen))
            }
        }
    }
