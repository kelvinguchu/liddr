package com.liddr.app.ui.driver.capture

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateOffsetAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size as CanvasSize
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

// What is drawn over the viewfinder. Teal is used the way the theme means it:
// a thin mark on the thing the camera has found.

/** The outline of a quad in unit space, as a path over a canvas of [size]. */
internal fun quadPath(corners: List<Offset>, size: CanvasSize) = Path().apply {
    corners.forEachIndexed { index, c -> if (index == 0) moveTo(c.x * size.width, c.y * size.height) else lineTo(c.x * size.width, c.y * size.height) }
    close()
}

/**
 * The live outline of the document, gliding between frames so it does not
 * jitter. With nothing found it gives way to corner marks showing where to
 * hold the document.
 */
@Composable
internal fun DocumentOverlay(quad: Quad?, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    // The last outline seen stays while it fades, so it does not snap away.
    val last = remember { arrayOfNulls<Quad>(1) }
    if (quad != null) last[0] = quad
    val shown = last[0] ?: Quad.inset(GUIDE_INSET)
    val found by animateFloatAsState(if (quad != null) 1f else 0f, tween(180), label = "outline")
    val corners = shown.corners.mapIndexed { index, corner ->
        animateOffsetAsState(Offset(corner.x, corner.y), tween(120), label = "corner $index").value
    }
    Canvas(modifier.fillMaxSize()) {
        if (found < 1f) cornerMarks(colors.onBackground.copy(alpha = 0.8f * (1f - found)), GUIDE_INSET)
        if (found > 0f) {
            val path = quadPath(corners, size)
            drawPath(path, colors.secondary.copy(alpha = 0.16f * found))
            drawPath(path, colors.secondary.copy(alpha = found), style = Stroke(OutlineStroke.toPx(), join = StrokeJoin.Round))
        }
    }
}

/** Corner marks for a vehicle photo: fit the vehicle between them. */
@Composable
internal fun FramingMarks(modifier: Modifier = Modifier) {
    val color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.8f)
    Canvas(modifier.fillMaxSize()) { cornerMarks(color, PHOTO_INSET) }
}

private fun DrawScope.cornerMarks(color: Color, inset: Float) {
    val arm = MarkArm.toPx()
    val stroke = Stroke(MarkStroke.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
    for ((cx, cy) in listOf(inset to inset, 1 - inset to inset, 1 - inset to 1 - inset, inset to 1 - inset)) {
        val x = cx * size.width
        val y = cy * size.height
        val dx = if (cx < 0.5f) arm else -arm
        val dy = if (cy < 0.5f) arm else -arm
        val mark = Path().apply {
            moveTo(x + dx, y)
            lineTo(x, y)
            lineTo(x, y + dy)
        }
        drawPath(mark, color, style = stroke)
    }
}

/** The selfie guide: everything outside the oval is dimmed, and the oval turns teal when the face is placed well. */
@Composable
internal fun FaceOval(ready: Boolean, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val ring by animateColorAsState(if (ready) colors.secondary else colors.onBackground.copy(alpha = 0.85f), label = "oval")
    Canvas(modifier.fillMaxSize()) {
        val width = size.width * OVAL_WIDTH
        val height = width * OVAL_SHAPE
        val oval = Rect(Offset((size.width - width) / 2, size.height * OVAL_CENTRE_Y - height / 2), CanvasSize(width, height))
        val outside = Path().apply {
            fillType = PathFillType.EvenOdd
            addRect(Rect(Offset.Zero, size))
            addOval(oval)
        }
        drawPath(outside, colors.background.copy(alpha = 0.6f))
        drawOval(ring, oval.topLeft, oval.size, style = Stroke((if (ready) OutlineStroke else MarkStroke).toPx()))
    }
}

/** A brief white blink over the viewfinder as a photo is taken. */
@Composable
internal fun ShutterBlink(shooting: Boolean, modifier: Modifier = Modifier) {
    val color = MaterialTheme.colorScheme.onBackground
    val blink = remember { Animatable(0f) }
    LaunchedEffect(shooting) {
        if (shooting) {
            blink.snapTo(0.7f)
            blink.animateTo(0f, tween(260))
        }
    }
    Canvas(modifier.fillMaxSize()) { if (blink.value > 0f) drawRect(color.copy(alpha = blink.value)) }
}

private const val GUIDE_INSET = 0.1f
private const val PHOTO_INSET = 0.06f
private const val OVAL_WIDTH = 0.7f
private const val OVAL_SHAPE = 1.32f
// The eyes of a face that fills the oval then sit near Guidance.kt's EYES_AT_Y.
private const val OVAL_CENTRE_Y = 0.45f
private val OutlineStroke = 3.dp
private val MarkStroke = 2.dp
private val MarkArm = 28.dp
