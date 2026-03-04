package com.liddr.app.ui.launch

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.theme.LiddrTheme
import compose.icons.TablerIcons
import compose.icons.tablericons.Car
import compose.icons.tablericons.User

@Composable
fun FirstScreen(modifier: Modifier = Modifier, onRoleSelected: (AccountRoleUi) -> Unit = {}) {
    val vis = rememberStaggeredEntrance(count = 4, initialDelayMs = 100, staggerMs = 90)
    val enter =
            fadeIn(tween(400, easing = FastOutSlowInEasing)) +
                    slideInVertically(tween(400, easing = FastOutSlowInEasing)) { it / 4 }

    OnboardingBackground(modifier) {
        Column(
                Modifier.fillMaxSize()
                        .windowInsetsPadding(WindowInsets.safeDrawing)
                        .padding(horizontal = 28.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.Start
        ) {
            AnimatedVisibility(vis[0], enter = enter) { LiddrLogo() }
            Spacer(Modifier.height(48.dp))

            AnimatedVisibility(vis[1], enter = enter) {
                Text(
                        "Choose your account type",
                        style = MaterialTheme.typography.headlineLarge,
                        fontWeight = FontWeight.ExtraBold,
                        color = MaterialTheme.colorScheme.onBackground
                )
            }
            Spacer(Modifier.height(40.dp))

            AnimatedVisibility(vis[2], enter = enter) {
                RoleCard(
                        icon = TablerIcons.User,
                        title = AccountRoleUi.RIDER.title,
                        subtitle = AccountRoleUi.RIDER.subtitle,
                        onClick = { onRoleSelected(AccountRoleUi.RIDER) }
                )
            }
            Spacer(Modifier.height(16.dp))

            AnimatedVisibility(vis[3], enter = enter) {
                RoleCard(
                        icon = TablerIcons.Car,
                        title = AccountRoleUi.DRIVER.title,
                        subtitle = AccountRoleUi.DRIVER.subtitle,
                        onClick = { onRoleSelected(AccountRoleUi.DRIVER) }
                )
            }
        }
    }
}

@Composable
private fun RoleCard(icon: ImageVector, title: String, subtitle: String, onClick: () -> Unit) {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.97f else 1f, tween(100), label = "press")

    Surface(
            onClick = onClick,
            modifier =
                    Modifier.fillMaxWidth().graphicsLayer {
                        scaleX = scale
                        scaleY = scale
                    },
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = if (pressed) 0.dp else 2.dp,
            shadowElevation = if (pressed) 1.dp else 6.dp,
            interactionSource = src
    ) {
        Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 24.dp),
                verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                    Modifier.size(52.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primaryContainer),
                    contentAlignment = Alignment.Center
            ) { Icon(icon, null, Modifier.size(26.dp), tint = MaterialTheme.colorScheme.primary) }
            Spacer(Modifier.size(18.dp))
            Column {
                Text(
                        title,
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                        subtitle,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun FirstScreenPreview() {
    LiddrTheme { FirstScreen() }
}
