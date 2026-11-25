package com.liddr.app.ui.booking

import com.liddr.app.ui.kit.Space
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.Dot
import com.google.android.gms.maps.model.Gap
import com.google.android.gms.maps.model.JointType
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.android.gms.maps.model.MapStyleOptions
import com.google.android.gms.maps.model.RoundCap
import com.google.maps.android.compose.CameraMoveStartedReason
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.liddr.app.R
import com.liddr.app.BuildConfig
import com.liddr.app.data.Coordinates
import com.liddr.app.data.RideStatus
import com.liddr.app.data.decodePolyline
import com.liddr.app.ui.kit.CircleButton
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.theme.Navy
import com.liddr.app.ui.theme.Night
import com.liddr.app.ui.theme.Teal
import com.liddr.app.ui.theme.TealBright
import compose.icons.TablerIcons
import compose.icons.tablericons.CurrentLocation

/** True when the build has a Maps key. Without one the app shows calm rings rather than a blank map. */
val mapsEnabled: Boolean get() = BuildConfig.MAPS_API_KEY.isNotBlank()

// Nairobi CBD, until the phone knows where the rider is.
private val Nairobi = LatLng(-1.2864, 36.8172)

/**
 * The map behind the booking and trip sheets. [status] is the ride's status, or
 * null before booking. The camera reframes only when the trip's stage changes,
 * the sheet resizes or the rider taps Recenter, never on a plain driver update,
 * and it stops following once the rider pans.
 */
@Composable
fun MapBackdrop(
    pickup: Coordinates?,
    dropoff: Coordinates?,
    driver: Coordinates?,
    route: String?,
    sheetHeight: Dp,
    modifier: Modifier = Modifier,
    status: String? = null,
) {
    if (!mapsEnabled) {
        Backdrop(modifier)
        return
    }
    val context = LocalContext.current
    val density = LocalDensity.current
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val start = pickup ?: driver ?: dropoff
    val camera = rememberCameraPositionState { position = CameraPosition.fromLatLngZoom(start?.latLng() ?: Nairobi, if (start == null) 12f else 16f) }
    var loaded by remember { mutableStateOf(false) }
    var following by remember { mutableStateOf(true) }
    var recenter by remember { mutableIntStateOf(0) }
    val path = remember(route) { route?.takeIf(String::isNotEmpty)?.let(::decodePolyline).orEmpty().map { it.latLng() } }
    val style = remember(dark) { MapStyleOptions.loadRawResourceStyle(context, if (dark) R.raw.map_dark else R.raw.map_light) }
    val (driverState, heading) = rememberDriverMarker(driver)
    val approaching = status == RideStatus.ACCEPTED || status == RideStatus.DRIVER_ARRIVING || status == RideStatus.ARRIVED
    val riding = status == RideStatus.IN_PROGRESS || status == RideStatus.COMPLETED

    Box(modifier.fillMaxSize()) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = camera,
            contentPadding = PaddingValues(top = MapTopClearance, bottom = sheetHeight),
            properties = MapProperties(mapStyleOptions = style, minZoomPreference = MIN_ZOOM, maxZoomPreference = MAX_ZOOM),
            uiSettings = MapUiSettings(
                zoomControlsEnabled = false, myLocationButtonEnabled = false, mapToolbarEnabled = false,
                compassEnabled = false, tiltGesturesEnabled = false, rotationGesturesEnabled = false,
            ),
            onMapLoaded = { loaded = true },
        ) {
            val px = { size: Dp -> with(density) { size.roundToPx() } }
            val pickupIcon = remember(dark) { pickupIcon(px(EndMarker), fill = if (dark) NightWhite else Navy, ring = if (dark) Night else NightWhite) }
            val destinationIcon = remember(dark) { destinationIcon(px(EndMarker), fill = Teal, ring = if (dark) Night else NightWhite) }
            val driverIcon = remember(dark, heading != null) {
                driverIcon(px(DriverMarker), body = if (dark) NightWhite else Navy, ring = if (dark) Navy else NightWhite, wedge = Teal, heading = heading != null)
            }
            if (path.size > 1) {
                // A cased line: a wide outline under a narrower stroke, faded while it isn't the next leg.
                val faded = approaching || status == RideStatus.SEARCHING
                val alpha = if (faded) 0.4f else 1f
                val casing = if (dark) Night else NightWhite
                val stroke = if (dark) TealBright else Navy
                Polyline(points = path, color = casing.copy(alpha = alpha), width = px(RouteCasing).toFloat(), zIndex = 1f, startCap = RoundCap(), endCap = RoundCap(), jointType = JointType.ROUND)
                Polyline(points = path, color = stroke.copy(alpha = alpha), width = px(RouteStroke).toFloat(), zIndex = 2f, startCap = RoundCap(), endCap = RoundCap(), jointType = JointType.ROUND)
            }
            if (approaching && driver != null && pickup != null) {
                // There is no road route for the approach, so a quiet dotted line rather than a fake one.
                Polyline(points = listOf(driverState.position, pickup.latLng()), color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f), width = px(ApproachStroke).toFloat(), pattern = listOf(Dot(), Gap(px(ApproachGap).toFloat())), zIndex = 3f)
            }
            if (pickup != null && !riding) {
                Marker(state = remember(pickup) { MarkerState(pickup.latLng()) }, icon = pickupIcon, anchor = Offset(0.5f, 0.5f), flat = true, zIndex = 4f, onClick = { true })
            }
            if (dropoff != null && !approaching) {
                Marker(state = remember(dropoff) { MarkerState(dropoff.latLng()) }, icon = destinationIcon, anchor = Offset(0.5f, 0.5f), flat = true, zIndex = 4f, onClick = { true })
            }
            if (driver != null) {
                Marker(state = driverState, icon = driverIcon, anchor = Offset(0.5f, 0.5f), flat = true, rotation = heading ?: 0f, zIndex = 5f, onClick = { true })
            }
        }
        if (!following) {
            CircleButton(TablerIcons.CurrentLocation, "Recenter the map", {
                following = true
                recenter++
            }, Modifier.align(Alignment.BottomEnd).padding(end = Gutter, bottom = sheetHeight + Space.md))
        }
    }

    // What the camera frames at each stage of the trip.
    val framed = when {
        approaching -> listOfNotNull(driver, pickup)
        status == RideStatus.IN_PROGRESS -> listOfNotNull(driver, dropoff)
        status == RideStatus.COMPLETED -> listOfNotNull(dropoff)
        else -> listOfNotNull(pickup, dropoff)
    }
    LaunchedEffect(loaded, status, pickup, dropoff, sheetHeight, recenter, driver != null) {
        if (!loaded || !following || framed.isEmpty()) return@LaunchedEffect
        val update = if (framed.size == 1) {
            CameraUpdateFactory.newLatLngZoom(framed.first().latLng(), SINGLE_POINT_ZOOM)
        } else {
            CameraUpdateFactory.newLatLngBounds(LatLngBounds.builder().apply { framed.forEach { include(it.latLng()) } }.build(), with(density) { FitPadding.roundToPx() })
        }
        runCatching { camera.animate(update, FIT_MS) }
    }
    LaunchedEffect(camera.isMoving) {
        if (camera.isMoving && camera.cameraMoveStartedReason == CameraMoveStartedReason.GESTURE) following = false
    }
}

/** Soft rings around the middle of the visible area: calm, and plainly not a map. */
@Composable
private fun Backdrop(modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    val ground = colors.surfaceContainerLow
    val ring = colors.outlineVariant
    val dot = colors.secondary
    Canvas(modifier.fillMaxSize()) {
        drawRect(ground)
        val centre = Offset(size.width / 2, size.height * 0.3f)
        for (radius in 1..6) drawCircle(ring.copy(alpha = 0.55f - radius * 0.07f), radius = radius * RingStep.toPx(), center = centre, style = Stroke(RingStroke.toPx()))
        drawCircle(dot.copy(alpha = 0.25f), radius = HaloRadius.toPx(), center = centre)
        drawCircle(dot, radius = DotRadius.toPx(), center = centre)
    }
}

private val NightWhite = Color.White
private const val MIN_ZOOM = 11f
private const val MAX_ZOOM = 18f
private const val SINGLE_POINT_ZOOM = 16.5f
private const val FIT_MS = 600

// Map geometry, from Fable's marker review.
private val MapTopClearance = 96.dp
private val EndMarker = 22.dp
private val DriverMarker = 40.dp
private val RouteCasing = 9.dp
private val RouteStroke = 6.dp
private val ApproachStroke = 4.dp
private val ApproachGap = 8.dp
private val FitPadding = 56.dp
private val RingStep = 56.dp
private val RingStroke = 1.dp
private val HaloRadius = 22.dp
private val DotRadius = 8.dp
