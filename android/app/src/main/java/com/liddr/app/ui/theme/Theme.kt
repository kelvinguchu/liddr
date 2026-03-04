package com.liddr.app.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

private val DarkColorScheme = darkColorScheme(
    primary = LightPrimary,
    onPrimary = DarkForeground,
    primaryContainer = DarkAccent,
    onPrimaryContainer = DarkForeground,
    secondary = DarkSecondary,
    onSecondary = DarkForeground,
    secondaryContainer = DarkMuted,
    onSecondaryContainer = DarkMutedForeground,
    tertiary = DarkChart2,
    onTertiary = DarkBackground,
    background = DarkBackground,
    onBackground = DarkForeground,
    surface = DarkCard,
    onSurface = DarkForeground,
    surfaceVariant = DarkSecondary,
    onSurfaceVariant = DarkMutedForeground,
    error = DarkDestructive,
    onError = DarkForeground,
    outline = DarkBorder,
    outlineVariant = DarkInput
)

private val LightColorScheme = lightColorScheme(
    primary = LightPrimary,
    onPrimary = LightBackground,
    primaryContainer = LightAccent,
    onPrimaryContainer = LightForeground,
    secondary = LightSecondary,
    onSecondary = LightForeground,
    secondaryContainer = LightMuted,
    onSecondaryContainer = LightMutedForeground,
    tertiary = LightChart2,
    onTertiary = LightBackground,
    background = LightBackground,
    onBackground = LightForeground,
    surface = LightCard,
    onSurface = LightForeground,
    surfaceVariant = LightSecondary,
    onSurfaceVariant = LightMutedForeground,
    error = LightDestructive,
    onError = LightBackground,
    outline = LightBorder,
    outlineVariant = LightInput
)

@Composable
fun LiddrTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }

        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}
