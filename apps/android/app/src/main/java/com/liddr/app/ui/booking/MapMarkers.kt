package com.liddr.app.ui.booking

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.google.android.gms.maps.model.BitmapDescriptor
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.MarkerState
import com.liddr.app.data.Coordinates
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sqrt

// Map markers drawn once into bitmaps: flat shapes centred on the coordinate,
// matching the route rail (navy circle for pickup, teal square for the destination).

internal fun Coordinates.latLng() = LatLng(lat, lng)

/** The pickup: a filled circle inside a contrasting ring. */
internal fun pickupIcon(px: Int, fill: Color, ring: Color): BitmapDescriptor = icon(px) { canvas, paint ->
    val r = px / 2f
    paint.color = ring.toArgb()
    canvas.drawCircle(r, r, r, paint)
    paint.color = fill.toArgb()
    canvas.drawCircle(r, r, r * 0.72f, paint)
}

/** The destination: a rounded square inside a contrasting ring. */
internal fun destinationIcon(px: Int, fill: Color, ring: Color): BitmapDescriptor = icon(px) { canvas, paint ->
    paint.color = ring.toArgb()
    canvas.drawRoundRect(RectF(0f, 0f, px.toFloat(), px.toFloat()), px * 0.3f, px * 0.3f, paint)
    val inset = px * 0.14f
    paint.color = fill.toArgb()
    canvas.drawRoundRect(RectF(inset, inset, px - inset, px - inset), px * 0.22f, px * 0.22f, paint)
}

/**
 * The driver: a disc with a ring, and a teal wedge at the top showing the way
 * they are moving. Without a heading yet, the wedge is left off rather than guessed.
 */
internal fun driverIcon(px: Int, body: Color, ring: Color, wedge: Color, heading: Boolean): BitmapDescriptor = icon(px) { canvas, paint ->
    val c = px / 2f
    paint.color = ring.toArgb()
    canvas.drawCircle(c, c, c * 0.78f, paint)
    paint.color = body.toArgb()
    canvas.drawCircle(c, c, c * 0.64f, paint)
    paint.color = wedge.toArgb()
    if (heading) {
        canvas.drawPath(Path().apply {
            moveTo(c, 0f)
            lineTo(c + c * 0.34f, c * 0.32f)
            lineTo(c - c * 0.34f, c * 0.32f)
            close()
        }, paint)
    }
    canvas.drawCircle(c, c, c * 0.2f, paint)
}

private fun icon(px: Int, draw: (Canvas, Paint) -> Unit): BitmapDescriptor {
    val bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
    draw(Canvas(bitmap), Paint(Paint.ANTI_ALIAS_FLAG))
    return BitmapDescriptorFactory.fromBitmap(bitmap)
}

/** Compass heading in degrees from [from] to [to], 0 = north, clockwise. */
internal fun headingDegrees(from: LatLng, to: LatLng): Float {
    val dx = (to.longitude - from.longitude) * cos(Math.toRadians((from.latitude + to.latitude) / 2))
    val dy = to.latitude - from.latitude
    val degrees = Math.toDegrees(atan2(dx, dy)).toFloat()
    return (degrees + 360f) % 360f
}

/** Straight-line distance in metres, close enough over a few kilometres. */
internal fun metresBetween(a: LatLng, b: LatLng): Double {
    val dx = (b.longitude - a.longitude) * cos(Math.toRadians((a.latitude + b.latitude) / 2)) * METRES_PER_DEGREE
    val dy = (b.latitude - a.latitude) * METRES_PER_DEGREE
    return sqrt(dx * dx + dy * dy)
}

/**
 * The driver's marker position, gliding between live updates instead of jumping,
 * and the heading worked out from successive positions.
 */
@Composable
internal fun rememberDriverMarker(driver: Coordinates?): Pair<MarkerState, Float?> {
    val state = remember { MarkerState(driver?.latLng() ?: LatLng(0.0, 0.0)) }
    var heading by remember { mutableStateOf<Float?>(null) }
    var placed by remember { mutableStateOf(driver != null) }
    var lastUpdate by remember { mutableLongStateOf(0L) }
    LaunchedEffect(driver) {
        val to = driver?.latLng() ?: return@LaunchedEffect
        val now = System.currentTimeMillis()
        val interval = (now - lastUpdate).coerceIn(MIN_GLIDE_MS, MAX_GLIDE_MS)
        lastUpdate = now
        val from = state.position
        val moved = metresBetween(from, to)
        if (!placed || moved > SNAP_METRES) {
            state.position = to
            placed = true
            return@LaunchedEffect
        }
        if (moved >= HEADING_METRES) heading = headingDegrees(from, to)
        val progress = Animatable(0f)
        progress.animateTo(1f, tween(interval.toInt(), easing = LinearEasing)) {
            state.position = LatLng(from.latitude + (to.latitude - from.latitude) * value, from.longitude + (to.longitude - from.longitude) * value)
        }
    }
    return state to heading
}

private const val METRES_PER_DEGREE = 111_320.0
private const val SNAP_METRES = 500.0
private const val HEADING_METRES = 12.0
private const val MIN_GLIDE_MS = 1_000L
private const val MAX_GLIDE_MS = 4_000L
