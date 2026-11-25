package com.liddr.app.ui.kit

import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.Density
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.geometry.Size as GeometrySize
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.liddr.app.ui.theme.PlateStyle

// The building blocks every screen shares, sized only from Tokens.kt: one
// filled primary action per screen, everything else quieter.

/** The one filled action on a screen. */
@Composable
fun PrimaryButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, busy: Boolean = false) {
    Button(
        onClick = onClick,
        enabled = enabled && !busy,
        modifier = modifier.fillMaxWidth().height(Size.control),
        shape = Corners.lg,
        contentPadding = PaddingValues(horizontal = Space.lg),
    ) {
        if (busy) {
            CircularProgressIndicator(Modifier.size(Size.icon), color = MaterialTheme.colorScheme.onPrimary, strokeWidth = SpinnerStroke)
        } else {
            Text(label, style = MaterialTheme.typography.titleMedium)
        }
    }
}

/** A quieter action beside the primary one. */
@Composable
fun SecondaryButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.height(Size.control),
        shape = Corners.lg,
        border = BorderStroke(Hairline, MaterialTheme.colorScheme.outline),
    ) {
        Text(label, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
    }
}

/** A text link with a full touch target, such as "Use email instead". */
@Composable
fun LinkButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.tertiary) {
    TextButton(onClick = onClick, modifier = modifier.height(Size.touch)) {
        Text(label, style = MaterialTheme.typography.titleSmall, color = color)
    }
}

/** A round button that floats over the map or sits in a top bar. */
@Composable
fun CircleButton(icon: ImageVector, description: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = colors.surface,
        border = BorderStroke(Hairline, colors.outlineVariant),
        shadowElevation = LowShadow,
        modifier = modifier.size(Size.touch).semantics { contentDescription = description },
    ) {
        Box(contentAlignment = Alignment.Center) { Icon(icon, null, Modifier.size(Size.icon), tint = colors.onSurface) }
    }
}

/** A small capitalised label above a heading, such as "STEP 1 OF 3". */
@Composable
fun Overline(text: String, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Text(text.uppercase(), modifier = modifier, style = MaterialTheme.typography.labelMedium, letterSpacing = 1.2.sp, color = color)
}

/** A segmented bar for a short flow such as sign-in. [step] counts from 1. */
@Composable
fun StepBar(step: Int, total: Int, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    Row(modifier.semantics { contentDescription = "Step $step of $total" }, horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
        repeat(total) { index ->
            Box(
                Modifier.weight(1f).height(StepHeight).clip(CircleShape)
                    .background(if (index < step) colors.secondary else colors.surfaceContainerHigh),
            )
        }
    }
}

/**
 * A number plate as riders see it on the street: black on white with a double
 * border, in the plate typeface, whatever the app's theme.
 */
@Composable
fun Plate(number: String, modifier: Modifier = Modifier, large: Boolean = false) {
    val ink = Color(0xFF0B0B0B)
    val size = if (large) PlateLargeText else PlateText
    val outer = RoundedCornerShape(if (large) Radius.sm else PlateSmallRadius)
    Box(
        modifier.semantics { contentDescription = "Plate $number" }
            .clip(outer)
            .background(Color.White)
            .border(if (large) PlateLargeBorder else PlateBorder, ink, outer)
            .padding(if (large) Space.xs else PlateNoInset)
            .border(if (large) Hairline else PlateNoInset, if (large) ink else Color.Transparent, RoundedCornerShape(if (large) PlateInnerRadius else PlateSmallRadius))
            .padding(horizontal = if (large) Space.lg else Space.sm, vertical = if (large) Space.sm else PlateSmallInset),
        contentAlignment = Alignment.Center,
    ) {
        Text(number, style = PlateStyle.copy(fontSize = size, lineHeight = size * 1.2f), color = ink)
    }
}

/** The sheet that sits over the map, edge to edge, with rounded top corners. */
@Composable
fun MapSheet(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val shape = Corners.sheet
    Column(
        modifier.fillMaxWidth().shadow(SheetShadow, shape).clip(shape).background(MaterialTheme.colorScheme.surface),
        content = content,
    )
}

/** A tinted block inside a sheet, such as the plate panel or a hint. */
@Composable
fun Panel(modifier: Modifier = Modifier, tint: Color = MaterialTheme.colorScheme.surfaceContainerLow, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().clip(Corners.lg).background(tint).padding(Space.lg), content = content)
}

/**
 * A card with a notch cut into each side at [cutAt], like a ticket's perforation.
 * Pair it with [Perforation] drawn at the same height.
 */
class TicketShape(private val cutAt: Dp, private val corner: Dp = Radius.lg, private val notch: Dp = TicketNotch) : Shape {
    override fun createOutline(size: GeometrySize, layoutDirection: LayoutDirection, density: Density): Outline = with(density) {
        val n = notch.toPx()
        val y = cutAt.toPx()
        val card = Path().apply { addRoundRect(RoundRect(0f, 0f, size.width, size.height, CornerRadius(corner.toPx()))) }
        val notches = Path().apply {
            addOval(Rect(-n, y - n, n, y + n))
            addOval(Rect(size.width - n, y - n, size.width + n, y + n))
        }
        Outline.Generic(Path.combine(PathOperation.Difference, card, notches))
    }
}

/** The dashed line across a ticket, between its notches. */
@Composable
fun Perforation(modifier: Modifier = Modifier) {
    val color = MaterialTheme.colorScheme.outlineVariant
    Canvas(modifier.fillMaxWidth().height(Rule)) {
        drawLine(color, Offset(0f, size.height / 2), Offset(size.width, size.height / 2), strokeWidth = Rule.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(Dash.toPx(), DashGap.toPx())))
    }
}

// Fixed geometry for the shapes above; not spacing, so not in Tokens.kt.
private val Hairline = 1.dp
private val Rule = 2.dp
private val Dash = 6.dp
private val DashGap = 5.dp
private val StepHeight = 4.dp
private val SpinnerStroke = 2.5.dp
private val LowShadow = 2.dp
private val SheetShadow = 16.dp
private val TicketNotch = 10.dp
private val PlateBorder = 2.dp
private val PlateLargeBorder = 3.dp
private val PlateNoInset = 0.dp
private val PlateSmallInset = 2.dp
private val PlateSmallRadius = 6.dp
private val PlateInnerRadius = 5.dp
private val PlateText = 20.sp
private val PlateLargeText = 44.sp
