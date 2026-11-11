package com.liddr.app.ui.booking

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.liddr.app.BuildConfig
import com.liddr.app.data.Coordinates
import com.liddr.app.data.decodePolyline

private fun Coordinates.latLng() = LatLng(lat, lng)

/** True when the build has a Maps key. Without one the app shows no map rather than a blank one. */
val mapsEnabled: Boolean get() = BuildConfig.MAPS_API_KEY.isNotBlank()

/** Pickup, destination, the route and, while the driver is on the way, where they are. */
@Composable
fun TripMap(pickup: Coordinates, dropoff: Coordinates?, driver: Coordinates?, route: String?, modifier: Modifier = Modifier) {
    if (!mapsEnabled) return
    val camera = rememberCameraPositionState { position = CameraPosition.fromLatLngZoom(pickup.latLng(), DEFAULT_ZOOM) }
    var loaded by remember { mutableStateOf(false) }
    val points = listOfNotNull(pickup, dropoff, driver)
    val path = remember(route) { route?.takeIf(String::isNotEmpty)?.let(::decodePolyline).orEmpty() }
    GoogleMap(
        modifier = modifier.fillMaxWidth().height(MAP_HEIGHT.dp).clip(RoundedCornerShape(16.dp)),
        cameraPositionState = camera,
        uiSettings = MapUiSettings(zoomControlsEnabled = false, myLocationButtonEnabled = false, mapToolbarEnabled = false),
        onMapLoaded = { loaded = true },
    ) {
        Marker(state = remember(pickup) { MarkerState(pickup.latLng()) }, title = "Pickup")
        dropoff?.let { Marker(state = remember(it) { MarkerState(it.latLng()) }, title = "Destination") }
        driver?.let {
            Marker(
                state = remember(it) { MarkerState(it.latLng()) },
                title = "Your driver",
                icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_ORANGE),
            )
        }
        if (path.size > 1) Polyline(points = path.map { it.latLng() }, color = MaterialTheme.colorScheme.primary, width = ROUTE_WIDTH)
    }
    LaunchedEffect(loaded, points) {
        if (!loaded || points.size < 2) return@LaunchedEffect
        val bounds = LatLngBounds.builder().apply { points.forEach { include(it.latLng()) } }.build()
        runCatching { camera.animate(CameraUpdateFactory.newLatLngBounds(bounds, FIT_PADDING_PX)) }
    }
}

private const val DEFAULT_ZOOM = 14f
private const val MAP_HEIGHT = 220
private const val ROUTE_WIDTH = 10f
private const val FIT_PADDING_PX = 120
