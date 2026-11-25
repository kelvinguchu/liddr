package com.liddr.app.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Account > Appearance can set Light or Dark apart from the phone, but Android
 * picks -night resources from the phone's setting. A night drawable once drew a
 * white wordmark on the light theme. Screens choose colours from the Compose
 * theme instead; values-night only colours the window before Compose draws.
 */
class NightResourceTest {
    @Test
    fun drawablesHaveNoNightVariants() {
        val res = File("src/main/res")
        assertTrue("run from the app module: ${res.absolutePath}", res.isDirectory)
        val night = res.listFiles().orEmpty()
            .filter { it.isDirectory && it.name.startsWith("drawable") && "night" in it.name }
            .flatMap { dir -> dir.listFiles().orEmpty().map { "${dir.name}/${it.name}" } }
        assertTrue("Pick these from MaterialTheme in Compose instead: $night", night.isEmpty())
    }
}
