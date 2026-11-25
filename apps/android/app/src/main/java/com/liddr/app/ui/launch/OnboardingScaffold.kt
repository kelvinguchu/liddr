package com.liddr.app.ui.launch

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.liddr.app.R

/** The flat page every screen sits on. Clear keeps backgrounds quiet so content leads. */
@Composable
fun OnboardingBackground(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    Box(modifier.fillMaxSize().background(MaterialTheme.colorScheme.background), content = content)
}

/**
 * The Liddr wordmark at its own proportions, so it is never squeezed. It follows
 * the app's theme, which Account > Appearance can set apart from the phone's.
 */
@Composable
fun LiddrLogo(modifier: Modifier = Modifier) {
    val night = MaterialTheme.colorScheme.background.luminance() < 0.5f
    Image(
        painterResource(if (night) R.drawable.liddr_logo_night else R.drawable.liddr_logo),
        "Liddr",
        contentScale = ContentScale.Fit,
        modifier = modifier.height(LogoHeight).aspectRatio(LOGO_WIDTH / LOGO_HEIGHT),
    )
}

@Composable
fun LegalFooter(modifier: Modifier = Modifier) {
    Text(
        "By continuing you agree to Liddr’s Terms & Privacy Policy.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
        modifier = modifier.fillMaxWidth(),
    )
}

// The wordmark drawable's viewport, which includes room so no letter is clipped.
private const val LOGO_WIDTH = 744f
private const val LOGO_HEIGHT = 312f
private val LogoHeight = 40.dp
