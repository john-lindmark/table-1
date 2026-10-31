package site.table1.events

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Every type handed to supabase-kt's decodeAs / decodeList / decodeSingle is looked up at run time, so one without
 * @Serializable compiles and only fails on screen ("Serializer for class … is not found", a shared cube on 2026-10-30).
 * This reads the sources and wants @Serializable on the line right above each such class.
 */
class DecodeTypesTest {
    private val skip = setOf("List", "Map", "String", "Int", "Long", "Double", "Boolean", "JsonElement", "JsonArray", "JsonObject")

    @Test fun decodedTypesAreSerializable() {
        val root = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "app/src/main/java") }.firstOrNull { it.isDirectory } ?: File("src/main/java")
        val files = root.walk().filter { it.extension == "kt" }.associateWith { it.readText() }
        val call = Regex("""\.decode(?:As|List|Single|SingleOrNull|AsOrNull)<([\w.<>, ]+)>\(""")
        val names = files.values.flatMap { t -> call.findAll(t).flatMap { m -> Regex("""[A-Z][\w.]*""").findAll(m.groupValues[1]).map { it.value.split('.').last() } } }
            .filterNot { it in skip }.toSet()
        // Nested names (JoinPreview.Wire) count by their last part.
        val missing = names.filter { n ->
            val decl = Regex("""(?m)^([ \t]*)((?:private |internal )?(?:data |enum )?class $n\b)""")
            val hits = files.values.flatMap { t -> decl.findAll(t).map { m -> t.substring(0, m.range.first).trimEnd().lines().last().trim() } }.toList()
            hits.isNotEmpty() && hits.none { it.startsWith("@Serializable") }
        }.sorted()
        assertEquals("decoded without @Serializable", emptyList<String>(), missing)
    }
}
