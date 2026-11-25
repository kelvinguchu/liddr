package com.liddr.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance

// Where something stands, in colour: teal is done, amber is with Liddr, red needs
// the person, grey is not started. Each comes as a pale wash to sit on, ink that
// reads on the wash, and a mark for icons, dots and bars.

/** One status colour: [wash] behind, [ink] for words on the wash, [mark] for icons and bars. */
@Immutable
data class StatusColors(val wash: Color, val ink: Color, val mark: Color)

private val AmberWash = Color(0xFFFCEFD3)
private val AmberInk = Color(0xFF855A0C)
private val AmberMark = Color(0xFFD99A1E)
private val AlertInk = Color(0xFFA32D2D)
private val AlertWash = Color(0xFFFBE7E7)
private val NightAmberWash = Color(0xFF3A2D12)
private val NightAmber = Color(0xFFF2B544)
private val NightAlertWash = Color(0xFF4A1F25)

/** The colours for a status, for the current theme. */
object Status {
    val done: StatusColors @Composable get() = if (night()) StatusColors(NightSelected, TealBright, TealBright) else StatusColors(TealTint, TealText, Teal)
    val waiting: StatusColors @Composable get() = if (night()) StatusColors(NightAmberWash, NightAmber, NightAmber) else StatusColors(AmberWash, AmberInk, AmberMark)
    val problem: StatusColors @Composable get() = if (night()) StatusColors(NightAlertWash, NightAlert, NightAlert) else StatusColors(AlertWash, AlertInk, Alert)
    val idle: StatusColors @Composable get() = MaterialTheme.colorScheme.let { StatusColors(it.surfaceContainerHigh, it.onSurfaceVariant, it.onSurfaceVariant) }
}

@Composable
private fun night() = MaterialTheme.colorScheme.background.luminance() < 0.5f
