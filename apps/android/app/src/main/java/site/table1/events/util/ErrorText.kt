package site.table1.events.util

/**
 * What a failure says on screen and in error reports (contract/android-errors-2026-11-14.md).
 *
 * supabase-kt builds a refused call's message as the server's message followed by the request: "URL: …",
 * "Headers: [Authorization=[Bearer <the person's access token>], apikey=[…], …]" and "Http Method: POST". Screens had
 * shown all of it (a player's screenshot carried their sign-in token), and Sentry got it in every reported exception.
 */
object ErrorText {
    const val FALLBACK = "Something went wrong."
    const val NETWORK = "Couldn't reach Table 1. Check your connection."

    private val jwt = Regex("eyJ[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]*")
    private val headers = Regex("\\n?\\s*Headers: \\[.*?(?=\\n\\s*Http Method:|\\z)", RegexOption.DOT_MATCHES_ALL)

    /** A message that carries the request supabase-kt appends, or a token. */
    fun looksRaw(text: String): Boolean =
        "\nURL: " in text || "Headers: [" in text || "Http Method:" in text || jwt.containsMatchIn(text)

    /** The server's own words: the first line that isn't the request, never a token. */
    fun shown(raw: String?): String {
        val line = raw?.lineSequence()?.map { it.trim() }
            ?.firstOrNull { it.isNotEmpty() && !it.startsWith("URL:") && !it.startsWith("Headers:") && !it.startsWith("Http Method:") }
            ?: return FALLBACK
        val clean = jwt.replace(line, "").trim()
        return clean.ifEmpty { FALLBACK }
    }

    /** Plain text passes through; a raw exception message is cut to its first line. */
    fun safe(text: String): String = if (looksRaw(text)) shown(text) else text

    /** What a screen says for [e]: the connection when the server couldn't be reached, else the server's words. */
    fun of(e: Throwable): String = when {
        Offline.isNetwork(e) -> NETWORK
        // supabase-kt keeps the server's own message apart from the text it builds around it.
        e is io.github.jan.supabase.exceptions.RestException && e.error.isNotBlank() -> shown(e.error)
        else -> shown(e.message)
    }

    /** For error reports: the message and URL kept, the headers and any token gone. */
    fun redacted(raw: String): String = jwt.replace(headers.replace(raw, ""), "[token]")
}
