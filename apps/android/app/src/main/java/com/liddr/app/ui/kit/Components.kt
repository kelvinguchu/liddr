package com.liddr.app.ui.kit

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.layout.layout
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextAlign
import compose.icons.TablerIcons
import compose.icons.tablericons.ChevronLeft

// Layout components built only from Tokens.kt, so every screen is put together
// the same way: a header, sections with headings, cards holding rows.

/** A pushed screen's top bar: back, then the title in titleLarge. */
@Composable
fun ScreenHeader(title: String, onBack: (() -> Unit)? = null, modifier: Modifier = Modifier, trailing: @Composable (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().then(modifier).padding(horizontal = Space.lg, vertical = Space.sm), verticalAlignment = Alignment.CenterVertically) {
        if (onBack != null) {
            CircleButton(TablerIcons.ChevronLeft, "Back", onBack)
            Spacer(Modifier.width(Space.md))
        }
        Text(title, style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onBackground, modifier = Modifier.weight(1f).semantics { heading() })
        trailing?.invoke()
    }
}

/** A root screen's title in headlineMedium, with an optional line above it. */
@Composable
fun ScreenTitle(title: String, eyebrow: String? = null, modifier: Modifier = Modifier) {
    Column(modifier) {
        eyebrow?.let { Text(it, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Text(title, style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.onBackground, modifier = Modifier.semantics { heading() })
    }
}

/**
 * A section's heading. It owns the space above and below it, and keeps room for
 * an action such as "See all" so the gap never changes when one appears.
 */
@Composable
fun SectionHeader(title: String, modifier: Modifier = Modifier, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().then(modifier).padding(top = Space.xl).height(Size.touch), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onBackground, modifier = Modifier.weight(1f).semantics { heading() })
        if (actionLabel != null && onAction != null) LinkButton(actionLabel, onAction)
    }
    Spacer(Modifier.height(Space.xs))
}

/** A card on the screen background. */
@Composable
fun LiddrCard(modifier: Modifier = Modifier, onClick: (() -> Unit)? = null, content: @Composable ColumnScope.() -> Unit) {
    val colors = MaterialTheme.colorScheme
    if (onClick != null) {
        Surface(onClick = onClick, shape = Corners.lg, color = colors.surfaceContainerLow, modifier = modifier.fillMaxWidth()) { Column(content = content) }
    } else {
        Surface(shape = Corners.lg, color = colors.surfaceContainerLow, modifier = modifier.fillMaxWidth()) { Column(content = content) }
    }
}

/**
 * A row in a list or card: optional leading slot, a title, optional supporting
 * text, optional trailing slot. One line is 56dp tall, two lines 72dp.
 */
@Composable
fun ListRow(
    title: String,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    titleColor: Color = MaterialTheme.colorScheme.onSurface,
    onClick: (() -> Unit)? = null,
    leading: @Composable (() -> Unit)? = null,
    trailing: @Composable (() -> Unit)? = null,
) {
    val colors = MaterialTheme.colorScheme
    Row(
        modifier.fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .heightIn(min = if (supporting == null) Size.row else Size.tallRow)
            .padding(horizontal = Space.lg, vertical = Space.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) {
            leading()
            Spacer(Modifier.width(Space.md))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = titleColor, maxLines = 1, overflow = TextOverflow.Ellipsis)
            supporting?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis) }
        }
        if (trailing != null) {
            Spacer(Modifier.width(Space.sm))
            trailing()
        }
    }
}

/** The line between rows in a card, starting under the row's text. */
@Composable
fun RowDivider(inset: Boolean = true) {
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant, modifier = Modifier.padding(start = if (inset) Space.lg + Size.icon + Space.md else Space.lg))
}

/** One choice among a few, such as System, Light, Dark. */
@Composable
fun SegmentedControl(options: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    Row(
        modifier.fillMaxWidth().clip(Corners.lg).background(colors.surfaceContainerLow).padding(Space.xs),
        horizontalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        options.forEachIndexed { index, label ->
            val picked = index == selected
            Box(
                Modifier.weight(1f).height(Size.chip).clip(Corners.md)
                    .background(if (picked) colors.primaryContainer else Color.Transparent)
                    .selectable(selected = picked, role = Role.RadioButton) { onSelect(index) },
                contentAlignment = Alignment.Center,
            ) {
                Text(label, style = MaterialTheme.typography.titleSmall, color = if (picked) colors.onPrimaryContainer else colors.onSurfaceVariant)
            }
        }
    }
}

/** A small tonal button beside a row, such as "Again". */
@Composable
fun SmallButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    Surface(onClick = onClick, shape = Corners.md, color = colors.secondaryContainer, modifier = modifier.height(Size.touch)) {
        Box(Modifier.padding(horizontal = Space.lg), contentAlignment = Alignment.Center) {
            Text(label, style = MaterialTheme.typography.labelLarge, color = colors.onSecondaryContainer)
        }
    }
}

/** A square tile for an illustration or icon at the start of a row. */
@Composable
fun Thumbnail(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    Box(
        modifier.size(Size.touch).clip(Corners.md).background(MaterialTheme.colorScheme.surfaceContainerHigh),
        contentAlignment = Alignment.Center,
        content = content,
    )
}

/**
 * A point on a route: a circle for the pickup, a teal square for the destination.
 * The same shapes mark the map.
 */
@Composable
fun RouteNode(pickup: Boolean, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    Box(modifier.size(Size.icon), contentAlignment = Alignment.Center) {
        if (pickup) {
            Box(Modifier.size(NodeSize).clip(CircleShape).background(colors.onSurface).border(NodeRing, colors.surfaceContainerLow, CircleShape))
        } else {
            Box(Modifier.size(NodeSize).clip(RoundedCornerShape(NodeCorner)).background(colors.secondary))
        }
    }
}

/**
 * Lets a row inside a padded column reach the screen edges, for scrolling rows
 * and full-width list rows that pad themselves.
 */
fun Modifier.bleedToEdges(gutter: Dp): Modifier = layout { measurable, constraints ->
    val extra = (gutter * 2).roundToPx()
    if (!constraints.hasBoundedWidth) {
        val placeable = measurable.measure(constraints)
        return@layout layout(placeable.width, placeable.height) { placeable.place(0, 0) }
    }
    val placeable = measurable.measure(constraints.copy(minWidth = constraints.minWidth + extra, maxWidth = constraints.maxWidth + extra))
    layout(placeable.width - extra, placeable.height) { placeable.place(-extra / 2, 0) }
}

/**
 * What a list or area says when it has nothing to show: empty, failed or not
 * found, with the one thing to do about it.
 */
@Composable
fun EmptyState(icon: ImageVector, title: String, body: String, modifier: Modifier = Modifier, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
    val colors = MaterialTheme.colorScheme
    Column(
        modifier.fillMaxWidth().padding(horizontal = Space.lg, vertical = Space.xl).semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.size(Size.touch).clip(CircleShape).background(colors.surfaceContainerHigh), contentAlignment = Alignment.Center) {
            Icon(icon, null, Modifier.size(Size.icon), tint = colors.onSurfaceVariant)
        }
        Spacer(Modifier.height(Space.md))
        Text(title, style = MaterialTheme.typography.titleMedium, color = colors.onSurface, textAlign = TextAlign.Center)
        Spacer(Modifier.height(Space.xs))
        Text(body, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, textAlign = TextAlign.Center)
        if (actionLabel != null && onAction != null) {
            Spacer(Modifier.height(Space.lg))
            SmallButton(actionLabel, onAction)
        }
    }
}

/** A grey stand-in for a row that is still loading, the same size as the row it becomes. */
@Composable
fun SkeletonRow(modifier: Modifier = Modifier, round: Boolean = false) {
    val colors = MaterialTheme.colorScheme
    val pulse by rememberInfiniteTransition(label = "skeleton").animateFloat(
        initialValue = 1f,
        targetValue = 0.5f,
        animationSpec = infiniteRepeatable(tween(PULSE_MS), RepeatMode.Reverse),
        label = "pulse",
    )
    val bone = colors.surfaceContainerHigh.copy(alpha = pulse)
    Row(
        modifier.fillMaxWidth().height(Size.tallRow).padding(horizontal = Space.lg).clearAndSetSemantics {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(Size.touch).clip(if (round) CircleShape else Corners.md).background(bone))
        Spacer(Modifier.width(Space.md))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Space.sm)) {
            Box(Modifier.fillMaxWidth(TITLE_BONE).height(BoneHeight).clip(CircleShape).background(bone))
            Box(Modifier.fillMaxWidth(DETAIL_BONE).height(BoneHeight).clip(CircleShape).background(bone))
        }
    }
}

/** One option in a list where exactly one is picked, with a radio mark at the end. */
@Composable
fun ChoiceRow(title: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, supporting: String? = null) {
    val colors = MaterialTheme.colorScheme
    Row(
        modifier.fillMaxWidth()
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .heightIn(min = if (supporting == null) Size.row else Size.tallRow)
            .padding(horizontal = Space.lg, vertical = Space.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
            supporting?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant) }
        }
        Spacer(Modifier.width(Space.md))
        Box(Modifier.size(Size.smallIcon).border(RadioRing, if (selected) colors.secondary else colors.outline, CircleShape), contentAlignment = Alignment.Center) {
            if (selected) Box(Modifier.size(RadioDot).clip(CircleShape).background(colors.secondary))
        }
    }
}

/** A text field with its label inside, on the app's corners and focus colour. */
@Composable
fun FormField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    singleLine: Boolean = true,
) {
    val colors = MaterialTheme.colorScheme
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = singleLine,
        textStyle = MaterialTheme.typography.bodyLarge,
        keyboardOptions = keyboardOptions,
        shape = Corners.lg,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = colors.secondary,
            focusedLabelColor = colors.tertiary,
            unfocusedBorderColor = colors.outlineVariant,
            cursorColor = colors.secondary,
        ),
        modifier = modifier.fillMaxWidth(),
    )
}

private val RadioRing = 2.dp
private val RadioDot = 10.dp
private const val PULSE_MS = 700
private const val TITLE_BONE = 0.55f
private const val DETAIL_BONE = 0.8f
private val BoneHeight = 12.dp
private val NodeSize = 14.dp
private val NodeRing = 3.dp
private val NodeCorner = 4.dp
