package com.liddr.app.ui.launch

import com.liddr.app.ui.kit.Perforation
import com.liddr.app.ui.kit.TicketShape
import com.liddr.app.ui.kit.RouteNode
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Corners
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.Plate
import com.liddr.app.ui.theme.LiddrTheme
import compose.icons.TablerIcons
import compose.icons.tablericons.ArrowRight

/** Welcome: what Liddr is, then ride or drive. */
@Composable
fun FirstScreen(modifier: Modifier = Modifier, onRoleSelected: (AccountRoleUi) -> Unit = {}) {
    val colors = MaterialTheme.colorScheme
    OnboardingBackground(modifier) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = Gutter)) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                Spacer(Modifier.height(Space.xl))
                LiddrLogo()
                Spacer(Modifier.height(Space.xxl))
                Text("Get across Nairobi, your way", style = MaterialTheme.typography.headlineLarge, color = colors.onBackground)
                Spacer(Modifier.height(Space.sm))
                Text(
                    "Boda or car, meet at a gate you know, and pay your driver with M-Pesa or cash.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = colors.onSurfaceVariant,
                )
                Spacer(Modifier.height(Space.xxl))
                SampleTicket()
                Spacer(Modifier.height(Space.xl))
            }
            RoleRow("Ride with Liddr", "Book rides and send packages", filled = true) { onRoleSelected(AccountRoleUi.RIDER) }
            Spacer(Modifier.height(Space.md))
            RoleRow("Drive with Liddr", "Earn with your motorbike or car", filled = false) { onRoleSelected(AccountRoleUi.DRIVER) }
            Spacer(Modifier.height(Space.lg))
            LegalFooter(Modifier.padding(bottom = Space.md))
        }
    }
}

@Composable
private fun RoleRow(title: String, subtitle: String, filled: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val background = if (filled) colors.primary else colors.surface
    val ink = if (filled) colors.onPrimary else colors.onSurface
    Surface(
        onClick = onClick,
        shape = Corners.lg,
        color = background,
        border = if (filled) null else androidx.compose.foundation.BorderStroke(Hairline, colors.outlineVariant),
        modifier = Modifier.fillMaxWidth().height(Size.tallRow),
    ) {
        Row(Modifier.padding(horizontal = Space.lg), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium, color = ink)
                Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = if (filled) ink.copy(alpha = 0.85f) else colors.onSurfaceVariant)
            }
            Icon(TablerIcons.ArrowRight, contentDescription = null, tint = ink, modifier = Modifier.size(Size.icon))
        }
    }
}

/** A small trip ticket that shows, without words, what booking looks like. */
@Composable
private fun SampleTicket() {
    val colors = MaterialTheme.colorScheme
    Surface(
        shape = TicketShape(cutAt = SampleCut),
        color = colors.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth().rotate(SampleTilt),
    ) {
        Column {
            Column(Modifier.height(SampleCut).padding(horizontal = Space.lg), verticalArrangement = Arrangement.Center) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    RouteNode(pickup = true)
                    Spacer(Modifier.width(Space.md))
                    Text("Sarit Centre, main gate", style = MaterialTheme.typography.titleSmall, color = colors.onSurface)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    RouteNode(pickup = false)
                    Spacer(Modifier.width(Space.md))
                    Text("Yaya Centre", style = MaterialTheme.typography.titleSmall, color = colors.onSurface)
                }
            }
            Perforation(Modifier.padding(horizontal = Space.lg))
            Row(Modifier.fillMaxWidth().padding(Space.lg), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Plate("KMFB 123A")
                Text("KES 210", style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
            }
        }
    }
}

@Preview(showBackground = true, backgroundColor = 0xFFF4F6F9)
@Composable
private fun FirstScreenPreview() {
    LiddrTheme(darkTheme = false) { FirstScreen() }
}

private val Hairline = 1.dp
private val SampleCut = 88.dp
private const val SampleTilt = -2f
