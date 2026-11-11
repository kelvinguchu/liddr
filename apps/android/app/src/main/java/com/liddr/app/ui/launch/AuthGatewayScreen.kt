package com.liddr.app.ui.launch

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.theme.LiddrTheme

@Composable
fun AuthGatewayScreen(
        role: AccountRoleUi,
        onBack: () -> Unit,
        onMethodSelected: (AuthMethodUi) -> Unit
) {
    OnboardingBackground {
        Column(
                Modifier.fillMaxSize()
                        .windowInsetsPadding(WindowInsets.safeDrawing)
                        .padding(horizontal = 28.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.SpaceBetween
        ) {
            Column {
                /* ── top bar ─────────────────────────────── */
                Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                ) {
                    TextButton(onClick = onBack) { Text("Back") }
                    Text(
                            role.title,
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(Modifier.height(10.dp))

                Column {
                    LiddrLogo()
                    Spacer(Modifier.height(18.dp))
                    Text(
                            "Sign in or create your account",
                            style = MaterialTheme.typography.headlineLarge,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onBackground
                    )
                }
                Spacer(Modifier.height(24.dp))
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    allOnboardingMethods.filter { role in it.allowedRoles }.forEach { m ->
                        MethodButton(label = m.label, icon = m.icon, onClick = { onMethodSelected(m) })
                    }
                }
            }
        }
    }
}

/* ── Single method button ─────────────────────────────────── */

@Composable
private fun MethodButton(
        label: String,
        icon: androidx.compose.ui.graphics.vector.ImageVector,
        onClick: () -> Unit
) {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.985f else 1f, tween(70), label = "btn")
    val colors = MaterialTheme.colorScheme

    Surface(
            onClick = onClick,
            modifier =
                    Modifier.fillMaxWidth().graphicsLayer {
                        scaleX = scale
                        scaleY = scale
                    },
            shape = RoundedCornerShape(16.dp),
            color = colors.surface,
            border = BorderStroke(1.dp, colors.outlineVariant),
            tonalElevation = if (pressed) 0.dp else 1.dp,
            shadowElevation = 0.dp,
            interactionSource = src
    ) {
        Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp),
                verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(icon, null, Modifier.size(22.dp), tint = colors.onSurface)
            Spacer(Modifier.width(16.dp))
            Text(
                    label,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.onSurface
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun GatewayPreview() {
    LiddrTheme {
        AuthGatewayScreen(AccountRoleUi.RIDER, onBack = {}, onMethodSelected = {})
    }
}
