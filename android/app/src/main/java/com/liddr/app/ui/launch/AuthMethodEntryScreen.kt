package com.liddr.app.ui.launch

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.theme.LiddrTheme

@Composable
fun AuthMethodEntryScreen(
        role: AccountRoleUi,
        mode: AuthModeUi,
        method: AuthMethodUi,
        onBack: () -> Unit,
        onContinue: () -> Unit
) {
    val colors = MaterialTheme.colorScheme
    val vis = rememberStaggeredEntrance(count = 4, initialDelayMs = 80, staggerMs = 70)
    val enter =
            fadeIn(tween(360, easing = FastOutSlowInEasing)) +
                    slideInVertically(tween(360, easing = FastOutSlowInEasing)) { it / 5 }

    val ctaSrc = remember { MutableInteractionSource() }
    val ctaPressed by ctaSrc.collectIsPressedAsState()
    val ctaScale by animateFloatAsState(if (ctaPressed) 0.97f else 1f, tween(80), label = "cta")

    OnboardingBackground {
        Column(
                Modifier.fillMaxSize()
                        .windowInsetsPadding(WindowInsets.safeDrawing)
                        .padding(horizontal = 28.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.SpaceBetween
        ) {
            Column {
                AnimatedVisibility(vis[0], enter = enter) {
                    TextButton(onClick = onBack) { Text("Back") }
                }
                Spacer(Modifier.height(10.dp))

                AnimatedVisibility(vis[1], enter = enter) { LiddrLogo() }
                Spacer(Modifier.height(36.dp))

                AnimatedVisibility(vis[2], enter = enter) {
                    Column {
                        Text(
                                method.label,
                                style = MaterialTheme.typography.headlineLarge,
                                fontWeight = FontWeight.Bold,
                                color = colors.onBackground
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                                "${mode.title} as ${role.title.lowercase()}",
                                style = MaterialTheme.typography.bodyLarge,
                                color = colors.onSurfaceVariant
                        )
                    }
                }
            }

            AnimatedVisibility(vis[3], enter = enter) {
                Column {
                    Button(
                            onClick = onContinue,
                            modifier =
                                    Modifier.fillMaxWidth().height(56.dp).graphicsLayer {
                                        scaleX = ctaScale
                                        scaleY = ctaScale
                                    },
                            shape = RoundedCornerShape(16.dp),
                            interactionSource = ctaSrc,
                            colors =
                                    ButtonDefaults.buttonColors(
                                            containerColor = colors.primary,
                                            contentColor = colors.onPrimary
                                    )
                    ) {
                        Text(
                                if (mode == AuthModeUi.SIGN_UP) "Create account" else "Continue",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.SemiBold
                        )
                    }
                }
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun EntryPreview() {
    LiddrTheme {
        AuthMethodEntryScreen(
                AccountRoleUi.RIDER,
                AuthModeUi.SIGN_UP,
                allOnboardingMethods.first(),
                onBack = {},
                onContinue = {}
        )
    }
}
