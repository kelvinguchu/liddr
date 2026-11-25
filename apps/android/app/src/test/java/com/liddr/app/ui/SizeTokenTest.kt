package com.liddr.app.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Screens size things only from ui/kit/Tokens.kt. A hand-typed dp value or a
 * one-off corner shape is how proportions drifted before, so this fails on them.
 * A fixed piece of geometry may be declared as a named `private val X = 2.dp`.
 */
class SizeTokenTest {
    private val ui = File("src/main/java/com/liddr/app/ui")

    // Where tokens and theme values are defined.
    private val definitions = setOf("kit", "theme")

    // Screens not yet on the kit. Every screen has moved; keep this empty.
    private val pending = emptySet<String>()

    private val handTyped = Regex("""\b\d+(\.\d+)?\.dp\b|RoundedCornerShape\(""")
    private val namedGeometry = Regex("""^private val [A-Za-z]+ = """)

    @Test
    fun screensUseTokens() {
        assertTrue("run from the app module: ${ui.absolutePath}", ui.isDirectory)
        val found = ui.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .map { it to it.relativeTo(ui).invariantSeparatorsPath }
            .filter { (_, path) -> path.substringBefore('/') !in definitions && path !in pending }
            .flatMap { (file, path) ->
                file.readLines().withIndex()
                    .filter { (_, line) -> handTyped.containsMatchIn(line) && !namedGeometry.containsMatchIn(line) && !line.trimStart().startsWith("//") }
                    .map { (index, line) -> "$path:${index + 1}: ${line.trim()}" }
            }
            .toList()
        assertTrue("Use Space, Radius, Corners or Size from ui/kit/Tokens.kt:\n" + found.joinToString("\n"), found.isEmpty())
    }

    @Test
    fun pendingFilesStillExist() {
        // A stale entry would quietly exempt a new file with the same name.
        val missing = pending.filterNot { File(ui, it).isFile }
        assertTrue("Remove from pending: $missing", missing.isEmpty())
    }
}
