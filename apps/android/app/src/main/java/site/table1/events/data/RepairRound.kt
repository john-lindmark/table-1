package site.table1.events.data

import site.table1.events.ui.components.parseInstant

/**
 * Re-pair a round (contract/repair-round-2026-11-09.md): the Live notice that an earlier result changed after the
 * current round was paired, the confirm alert, and how a round is named. Cases: testdata/repair-round/cases.json.
 */
object RepairRound {
    data class Prompt(val round: Int, val changed: List<Int>, val text: String)
    data class Confirm(val title: String, val message: String, val results: Int)

    /** The current round, if it may be re-paired: the latest round, still active. */
    fun repairable(rounds: List<RoundRow>): RoundRow? =
        rounds.maxByOrNull { it.number }?.takeIf { it.status == "active" }

    /** "A round 2 result changed after round 3 was paired." when the organizer corrected an earlier round since. */
    fun prompt(rounds: List<RoundRow>): Prompt? {
        val current = repairable(rounds) ?: return null
        val paired = parseInstant(current.pairingsPublishedAt) ?: return null
        val changed = rounds
            .filter { it.number < current.number }
            .filter { r -> r.matches.any { m -> !m.isBye && m.resultSource == "organizer" && (parseInstant(m.updatedAt) ?: 0L) > paired } }
            .map { it.number }
            .sorted()
        if (changed.isEmpty()) return null
        val text = if (changed.size == 1) "A round ${changed[0]} result changed after round ${current.number} was paired."
        else "Results in rounds ${andList(changed.map { it.toString() })} changed after round ${current.number} was paired."
        return Prompt(current.number, changed, text)
    }

    private fun andList(xs: List<String>) =
        if (xs.size <= 1) xs.joinToString("") else xs.dropLast(1).joinToString(", ") + " and " + xs.last()

    /** "round 3", or "the quarterfinals" / "the semifinals" / "the final" in a top 8. */
    fun label(stage: String?, number: Int): String = when (stage) {
        "quarterfinal" -> "the quarterfinals"
        "semifinal" -> "the semifinals"
        "final" -> "the final"
        else -> "round $number"
    }

    /** Results already in (byes and unreported matches don't count). */
    fun resultsIn(matches: List<Pair<Boolean, String>>): Int = matches.count { (bye, status) -> !bye && status != "pending" }

    fun confirm(label: String, matches: List<Pair<Boolean, String>>): Confirm {
        val results = resultsIn(matches)
        val base = "New pairings from the standings as they are now. Players get their new tables and the clock starts again."
        val cleared = when (results) {
            0 -> ""
            1 -> " The 1 result already in for $label is cleared."
            else -> " The $results results already in for $label are cleared."
        }
        return Confirm("Re-pair $label?", base + cleared, results)
    }
}
