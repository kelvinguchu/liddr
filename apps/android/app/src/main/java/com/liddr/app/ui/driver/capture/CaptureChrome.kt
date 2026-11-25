package com.liddr.app.ui.driver.capture

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size as CanvasSize
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.kit.CircleButton
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Space
import compose.icons.TablerIcons
import compose.icons.tablericons.X

// The camera's frame, the same for every step: a bar with Close and the
// document's name, a 3:4 picture with a few words of guidance over it, then the
// controls. Nothing else to read: the picture is what the driver looks at.
// It is always drawn in the night colours, as cameras are, whatever the theme.

/** Width over height of the viewfinder and of every photo it takes. */
internal const val PICTURE_SHAPE = 3f / 4f

@Composable
internal fun CaptureFrame(
    title: String,
    onClose: () -> Unit,
    hint: String,
    trailing: @Composable () -> Unit = {},
    picture: @Composable BoxScope.() -> Unit,
    controls: @Composable () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxSize().background(colors.background).windowInsetsPadding(WindowInsets.safeDrawing)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Gutter, vertical = Space.sm), verticalAlignment = Alignment.CenterVertically) {
            CircleButton(TablerIcons.X, "Close the camera", onClose)
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                color = colors.onBackground,
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).padding(horizontal = Space.md).semantics { heading() },
            )
            // The title stays centred whether or not there is a button on the right.
            Box(Modifier.size(Size.touch)) { trailing() }
        }
        Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = Space.sm), contentAlignment = Alignment.Center) {
            Box(Modifier.aspectRatio(PICTURE_SHAPE).clip(Corners.lg).background(colors.surfaceContainerLowest)) {
                picture()
                if (hint.isNotEmpty()) {
                    Text(
                        hint,
                        style = MaterialTheme.typography.titleSmall,
                        color = colors.onBackground,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.align(Alignment.BottomCenter).padding(Space.lg)
                            .clip(CircleShape).background(colors.background.copy(alpha = HINT_BACKING))
                            .padding(horizontal = Space.lg, vertical = Space.sm)
                            .semantics { liveRegion = LiveRegionMode.Polite },
                    )
                }
            }
        }
        Spacer(Modifier.height(Space.lg))
        Box(Modifier.fillMaxWidth().height(ControlsHeight).padding(horizontal = Gutter), contentAlignment = Alignment.Center) { controls() }
        Spacer(Modifier.height(Space.sm))
    }
}

/**
 * The shutter: a ring around a pearl disc. The ring fills in teal while a
 * steady shot counts down to taking itself, and the disc dims when the camera
 * is not ready to take one.
 */
@Composable
internal fun ShutterButton(enabled: Boolean, busy: Boolean, progress: Float, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val press by animateFloatAsState(if (pressed && enabled) 0.9f else 1f, label = "shutter press")
    val fill by animateFloatAsState(progress, label = "shutter countdown")
    Box(
        modifier.size(ShutterSize)
            .clickable(interaction, indication = null, enabled = enabled && !busy, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Take the photo" },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = ShutterRing.toPx()
            val inset = stroke / 2
            val arc = CanvasSize(size.width - stroke, size.height - stroke)
            drawArc(colors.onBackground.copy(alpha = if (enabled) 1f else 0.35f), 0f, 360f, false, Offset(inset, inset), arc, style = Stroke(stroke))
            if (fill > 0f) drawArc(colors.secondary, -90f, 360f * fill, false, Offset(inset, inset), arc, style = Stroke(stroke, cap = StrokeCap.Round))
        }
        Box(
            Modifier.size(ShutterDisc).scale(press).clip(CircleShape)
                .background(colors.primary.copy(alpha = if (enabled) 1f else 0.3f)),
            contentAlignment = Alignment.Center,
        ) {
            if (busy) CircularProgressIndicator(Modifier.size(Size.icon), color = colors.onPrimary, strokeWidth = SpinnerStroke)
        }
    }
}

private val ControlsHeight = 88.dp
private val ShutterSize = 76.dp
private val ShutterDisc = 58.dp
private val ShutterRing = 4.dp
private val SpinnerStroke = 2.5.dp

// Dark enough to read over any picture, light enough to still see through.
private const val HINT_BACKING = 0.72f
