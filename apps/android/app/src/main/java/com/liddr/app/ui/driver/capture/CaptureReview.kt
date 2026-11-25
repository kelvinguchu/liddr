package com.liddr.app.ui.driver.capture

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.SecondaryButton
import com.liddr.app.ui.kit.Space
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The photo just taken, to keep or retake. A document also shows its outline
 * with a handle on each corner, because a person knows where the page ends
 * better than the detector does.
 */
@Composable
internal fun ReviewStage(spec: CaptureSpec, shot: Shot, onRetake: () -> Unit, onUse: (ByteArray) -> Unit, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val document = spec.kind == CaptureKind.DOCUMENT
    val image = remember(shot) { shot.bitmap.asImageBitmap() }
    var quad by remember(shot) { mutableStateOf(shot.quad) }
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }

    fun use() {
        busy = true
        problem = null
        val outline = quad
        scope.launch {
            // Straightening a full photo takes a moment, so it runs off the main thread.
            val jpeg = withContext(Dispatchers.Default) { if (document) documentJpeg(shot.bitmap, outline, spec.documentType) else photoJpeg(shot.bitmap) }
            if (jpeg == null) {
                problem = "Couldn't use that. Retake it"
                busy = false
            } else {
                onUse(jpeg)
            }
        }
    }

    CaptureFrame(
        title = spec.title,
        onClose = onClose,
        hint = problem ?: if (document) "Adjust the corners" else "",
        picture = {
            // Sized to the photo itself, so the outline lines up even if a camera's picture is not quite 3:4.
            Box(Modifier.align(Alignment.Center).aspectRatio(image.width.toFloat() / image.height)) {
                Image(image, "The photo you took", Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
                if (document) CornerEditor(image, quad, enabled = !busy) { quad = it }
            }
        },
        controls = {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Space.md), verticalAlignment = Alignment.CenterVertically) {
                SecondaryButton("Retake", onRetake, Modifier.weight(1f), enabled = !busy)
                PrimaryButton("Use this photo", ::use, Modifier.weight(1f), busy = busy)
            }
        },
    )
}

// The smallest outline a drag may leave, as a share of the photo.
private const val MIN_OUTLINE = 0.02f
private const val LOUPE_ZOOM = 2.5f

/** The outline over the photo. Dragging near a corner moves it, with a magnified view of where it sits. */
@Composable
private fun CornerEditor(image: ImageBitmap, quad: Quad, enabled: Boolean, onChange: (Quad) -> Unit) {
    val colors = MaterialTheme.colorScheme
    val current by rememberUpdatedState(quad)
    val change by rememberUpdatedState(onChange)
    var held by remember { mutableIntStateOf(-1) }
    Canvas(
        Modifier.fillMaxSize().pointerInput(enabled) {
            if (!enabled) return@pointerInput
            awaitEachGesture {
                val down = awaitFirstDown()
                val reach = HandleReach.toPx()
                val index = current.corners.indices
                    .minBy { (Offset(current.corners[it].x * size.width, current.corners[it].y * size.height) - down.position).getDistance() }
                val corner = Offset(current.corners[index].x * size.width, current.corners[index].y * size.height)
                if ((corner - down.position).getDistance() > reach) return@awaitEachGesture
                // The corner keeps its distance from the finger, so it does not jump on touch.
                val grip = corner - down.position
                down.consume()
                held = index
                try {
                    drag(down.id) { pointer ->
                        val to = pointer.position + grip
                        val moved = current.withCorner(index, Pt(to.x / size.width, to.y / size.height))
                        if (moved.isConvex() && moved.area() >= MIN_OUTLINE) change(moved)
                        pointer.consume()
                    }
                } finally {
                    held = -1
                }
            }
        },
    ) {
        val corners = quad.corners.map { Offset(it.x, it.y) }
        val outline = quadPath(corners, size)
        val outside = Path().apply {
            fillType = PathFillType.EvenOdd
            addRect(Rect(Offset.Zero, size))
            addPath(outline)
        }
        drawPath(outside, colors.background.copy(alpha = 0.55f))
        drawPath(outline, colors.secondary, style = Stroke(OutlineStroke.toPx(), join = StrokeJoin.Round))
        corners.forEachIndexed { index, c ->
            val at = Offset(c.x * size.width, c.y * size.height)
            val radius = (if (index == held) HandleHeld else Handle).toPx()
            drawCircle(colors.background.copy(alpha = 0.4f), radius, at)
            drawCircle(colors.secondary, radius, at, style = Stroke(OutlineStroke.toPx()))
        }
        if (held >= 0) {
            // A magnified view in the far top corner, clear of the finger.
            val at = Offset(corners[held].x * size.width, corners[held].y * size.height)
            val radius = LoupeRadius.toPx()
            val margin = Space.md.toPx()
            val centre = Offset(if (corners[held].x < 0.5f) size.width - margin - radius else margin + radius, margin + radius)
            clipPath(Path().apply { addOval(Rect(centre, radius)) }) {
                drawRect(colors.surfaceContainerLowest)
                withTransform({
                    translate(centre.x - LOUPE_ZOOM * at.x, centre.y - LOUPE_ZOOM * at.y)
                    scale(LOUPE_ZOOM, LOUPE_ZOOM, Offset.Zero)
                }) {
                    drawImage(image, dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt()))
                    drawPath(outline, colors.secondary, style = Stroke(OutlineStroke.toPx() / LOUPE_ZOOM, join = StrokeJoin.Round))
                }
            }
            drawCircle(colors.onBackground, radius, centre, style = Stroke(LoupeRing.toPx()))
        }
    }
}

private val OutlineStroke = 3.dp
private val Handle = 11.dp
private val HandleHeld = 15.dp
private val HandleReach = 48.dp
private val LoupeRadius = 52.dp
private val LoupeRing = 2.dp
