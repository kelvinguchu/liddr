package com.liddr.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Every surface token is set, so Material never falls back to its own purples.
private val LightColorScheme = lightColorScheme(
    primary = Navy,
    onPrimary = White,
    primaryContainer = TealTint,
    onPrimaryContainer = TealText,
    secondary = Teal,
    onSecondary = OnTeal,
    secondaryContainer = MistDeep,
    onSecondaryContainer = Navy,
    tertiary = Teal,
    onTertiary = OnTeal,
    tertiaryContainer = TealTint,
    onTertiaryContainer = TealText,
    background = White,
    onBackground = Navy,
    surface = White,
    onSurface = Navy,
    surfaceVariant = Mist,
    onSurfaceVariant = Slate,
    surfaceTint = White,
    surfaceBright = White,
    surfaceDim = MistDeep,
    surfaceContainerLowest = White,
    surfaceContainerLow = Mist,
    surfaceContainer = Mist,
    surfaceContainerHigh = MistDeep,
    surfaceContainerHighest = MistDeep,
    inverseSurface = Navy,
    inverseOnSurface = White,
    inversePrimary = Teal,
    outline = Line,
    outlineVariant = Line,
    error = Alert,
    onError = White,
    errorContainer = Color(0xFFFBE7E7),
    onErrorContainer = Alert,
    scrim = Navy,
)

private val DarkColorScheme = darkColorScheme(
    primary = Teal,
    onPrimary = OnTeal,
    primaryContainer = NightHigh,
    onPrimaryContainer = NightText,
    secondary = Teal,
    onSecondary = OnTeal,
    secondaryContainer = NightHigh,
    onSecondaryContainer = NightText,
    tertiary = Teal,
    onTertiary = OnTeal,
    tertiaryContainer = NightHigh,
    onTertiaryContainer = NightText,
    background = Night,
    onBackground = NightText,
    surface = NightSurface,
    onSurface = NightText,
    surfaceVariant = NightRaised,
    onSurfaceVariant = NightMuted,
    surfaceTint = NightSurface,
    surfaceBright = NightHigh,
    surfaceDim = Night,
    surfaceContainerLowest = Night,
    surfaceContainerLow = NightSurface,
    surfaceContainer = NightRaised,
    surfaceContainerHigh = NightHigh,
    surfaceContainerHighest = NightHigh,
    inverseSurface = NightText,
    inverseOnSurface = Navy,
    inversePrimary = Navy,
    outline = NightLine,
    outlineVariant = NightLine,
    error = NightAlert,
    onError = Night,
    errorContainer = Color(0xFF4A1F25),
    onErrorContainer = NightAlert,
    scrim = Night,
)

/** Liddr's Clear theme. Brand colours always win over the phone's wallpaper colours. */
@Composable
fun LiddrTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme,
        typography = Typography,
        content = content,
    )
}
