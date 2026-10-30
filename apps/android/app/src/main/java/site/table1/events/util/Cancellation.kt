package site.table1.events.util

import kotlinx.coroutines.CancellationException

/**
 * A load cancelled because a newer one replaced it (at launch, the app coming to the foreground restarts the
 * Events, Account and Library loads) isn't a failure: rethrow it so the coroutine ends quietly instead of
 * showing "StandaloneCoroutine was cancelled" until the newer load lands. Same rule as iOS `isCancellation`.
 */
fun Throwable.rethrowIfCancelled() {
    if (this is CancellationException) throw this
}
