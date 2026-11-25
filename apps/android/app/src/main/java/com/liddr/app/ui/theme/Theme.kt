package com.liddr.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Every surface token is set, so Material never falls back to its own purples.
private val LightColorScheme = lightColorScheme(
    // The one action, and selected tabs, segments and chips: navy, like the trim.
    primary = Navy,
    onPrimary = White,
    primaryContainer = Navy,
    onPrimaryContainer = White,
    // The stripe: focus rings, radio dots, progress, stars, a chosen item's mark.
    secondary = Teal,
    onSecondary = White,
    // Quiet fills: small buttons, avatars, a chosen row.
    secondaryContainer = PearlShade,
    onSecondaryContainer = Navy,
    // Links and inline actions.
    tertiary = TealText,
    onTertiary = White,
    // Information panels.
    tertiaryContainer = TealTint,
    onTertiaryContainer = Navy,
    background = White,
    onBackground = Navy,
    surface = White,
    onSurface = Navy,
    surfaceVariant = Pearl,
    onSurfaceVariant = Slate,
    surfaceTint = White,
    surfaceBright = White,
    surfaceDim = PearlDeep,
    surfaceContainerLowest = White,
    surfaceContainerLow = Pearl,
    surfaceContainer = Pearl,
    surfaceContainerHigh = PearlDeep,
    surfaceContainerHighest = PearlDeep,
    inverseSurface = Navy,
    inverseOnSurface = White,
    inversePrimary = TealBright,
    outline = Line,
    outlineVariant = Line,
    error = Alert,
    onError = White,
    errorContainer = Color(0xFFFBE7E7),
    onErrorContainer = Alert,
    scrim = Navy,
)

private val DarkColorScheme = darkColorScheme(
    // At night the action is the brightest thing on screen: pearl with navy text.
    primary = NightText,
    onPrimary = Navy,
    primaryContainer = NightText,
    onPrimaryContainer = Navy,
    secondary = TealBright,
    onSecondary = Night,
    secondaryContainer = NightHigh,
    onSecondaryContainer = NightText,
    tertiary = TealBright,
    onTertiary = Night,
    tertiaryContainer = NightSelected,
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
    // Cards sit a clear step above the background so they read at night.
    surfaceContainerLow = NightRaised,
    surfaceContainer = NightRaised,
    surfaceContainerHigh = NightHigh,
    surfaceContainerHighest = NightHigh,
    inverseSurface = NightText,
    inverseOnSurface = Navy,
    inversePrimary = TealText,
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
