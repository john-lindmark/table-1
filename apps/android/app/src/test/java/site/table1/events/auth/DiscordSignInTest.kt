package site.table1.events.auth

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/* Discord accounts take the name step like email (contract/discord-sign-in-2026-10-29.md) against
   testdata/discord-sign-in/cases.json (also iOS DiscordSignInTests and web discordSignIn.test.ts). */
class DiscordSignInTest {
    @Serializable private data class NeedsName(val name: String, val providers: List<String>, val first_name: String?, val needs: Boolean)
    @Serializable private data class Cases(val needsName: List<NeedsName>)

    private val cases = Json { ignoreUnknownKeys = true }.decodeFromString<Cases>(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/discord-sign-in") }
            .first { it.isDirectory }, "cases.json").readText(),
    )

    @Test fun needsName() {
        assertTrue(cases.needsName.isNotEmpty())
        for (c in cases.needsName) assertEquals(c.name, c.needs, SignIn.needsName(c.providers, c.first_name))
    }
}
