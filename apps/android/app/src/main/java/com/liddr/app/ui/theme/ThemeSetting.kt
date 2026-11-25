package com.liddr.app.ui.theme

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Whether the app follows the phone's light or dark setting, or keeps one. */
enum class ThemeChoice(val label: String) { SYSTEM("System"), LIGHT("Light"), DARK("Dark") }

/** The rider's theme choice, kept on this phone only. It is a display preference, not account data. */
class ThemeSetting(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("liddr_display", Context.MODE_PRIVATE)
    private val _choice = MutableStateFlow(read())
    val choice: StateFlow<ThemeChoice> = _choice.asStateFlow()

    fun set(choice: ThemeChoice) {
        prefs.edit().putString(KEY, choice.name).apply()
        _choice.value = choice
    }

    private fun read(): ThemeChoice = prefs.getString(KEY, null)?.let { saved -> ThemeChoice.entries.firstOrNull { it.name == saved } } ?: ThemeChoice.SYSTEM

    private companion object {
        const val KEY = "theme"
    }
}
