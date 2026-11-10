package com.liddr.app.ui.booking

import android.graphics.BitmapFactory
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.liddr.app.data.DriverCard
import com.liddr.app.data.Ride
import com.liddr.app.data.RideStatus
import com.liddr.app.data.distanceMetres
import com.liddr.app.ui.launch.AuthError
import com.liddr.app.ui.launch.AuthPrimaryButton
import com.liddr.app.ui.launch.AuthProgress

private val cancelReasons = listOf(
    "rider_changed_mind" to "I changed my mind",
    "driver_not_moving" to "My driver isn't moving",
    "driver_too_far" to "My driver is too far away",
    "cannot_contact_driver" to "I can't reach my driver",
    "safety_concern" to "I feel unsafe",
    "emergency" to "I have an emergency",
)

internal fun headline(status: String) = when (status) {
    RideStatus.SEARCHING -> "Finding your driver"
    RideStatus.ACCEPTED -> "Your driver is on the way"
    RideStatus.DRIVER_ARRIVING -> "Your driver is almost there"
    RideStatus.ARRIVED -> "Your driver has arrived"
    RideStatus.IN_PROGRESS -> "On your way"
    RideStatus.COMPLETED -> "You've arrived"
    RideStatus.CANCELLED -> "This ride was cancelled"
    RideStatus.NO_DRIVERS -> "No drivers are available"
    else -> "Checking your ride"
}

internal fun money(kes: Int) = "KES %,d".format(kes)

internal fun minutes(seconds: Int) = "${(seconds + 59) / 60} min"

internal fun kilometres(metres: Int) = "%.1f km".format(metres / 1000.0)

internal fun formatSurge(bps: Int) = "%.1f".format(bps / 10_000.0)

@Composable
internal fun TripScreen(state: BookingUiState, viewModel: BookingViewModel) {
    val ride = state.ride ?: return
    var askReason by rememberSaveable { mutableStateOf(false) }
    Page {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            Spacer(Modifier.height(40.dp))
            Heading(headline(ride.status))
            Spacer(Modifier.height(6.dp))
            TripDetail(ride)
            if (state.reconnecting) {
                Spacer(Modifier.height(8.dp))
                Text("Reconnecting…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.height(24.dp))
            if (ride.status == RideStatus.SEARCHING) {
                Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { AuthProgress() }
            }
            ride.driver?.let { DriverPanel(it, state.driverPhoto) }
            if (ride.status == RideStatus.COMPLETED) {
                Spacer(Modifier.height(4.dp))
                RatingForm(state.busy, state.error, onSubmit = viewModel::submitRating, onSkip = viewModel::skipRating)
            } else {
                AuthError(state.error)
            }
        }
        TripActions(ride, state.busy, onCancel = {
            if (ride.status == RideStatus.SEARCHING) viewModel.cancel("rider_changed_mind") else askReason = true
        }, onDone = viewModel::finishTrip, onRetry = viewModel::tryAgain)
    }
    if (askReason) {
        AlertDialog(
            onDismissRequest = { askReason = false },
            containerColor = MaterialTheme.colorScheme.surface,
            title = { Text("Why are you cancelling?") },
            text = {
                Column {
                    Text("Repeated cancellations can pause your bookings, unless the driver was at fault.", style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.height(8.dp))
                    cancelReasons.forEach { (code, label) ->
                        TextButton(onClick = {
                            askReason = false
                            viewModel.cancel(code)
                        }, modifier = Modifier.fillMaxWidth()) { Text(label) }
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { askReason = false }) { Text("Keep my ride") } },
        )
    }
}

@Composable
private fun TripDetail(ride: Ride) {
    val text = when (ride.status) {
        RideStatus.SEARCHING -> "Fare ${money(ride.fareKes)}. We'll match you with the closest driver."
        RideStatus.ACCEPTED, RideStatus.DRIVER_ARRIVING -> ride.driverLocation?.let { "About ${kilometres(distanceMetres(it, ride.pickup).toInt())} away" } ?: "Fare ${money(ride.fareKes)}"
        RideStatus.ARRIVED -> "Meet your driver at the pickup point."
        RideStatus.IN_PROGRESS -> "Fare ${money(ride.fareKes)}. Pay your driver directly at the end."
        RideStatus.COMPLETED -> "Please pay your driver ${money(ride.fareKes)} with cash or M-Pesa."
        RideStatus.NO_DRIVERS -> "Nobody nearby could take this trip. You weren't charged."
        else -> "You weren't charged."
    }
    BodyText(text)
}

@Composable
private fun DriverPanel(driver: DriverCard, photo: ByteArray?) {
    val colors = MaterialTheme.colorScheme
    Surface(shape = RoundedCornerShape(16.dp), color = colors.surface, border = BorderStroke(1.dp, colors.outlineVariant), modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            DriverAvatar(driver.name, photo)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(driver.name ?: "Your driver", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.onSurface)
                val rating = driver.rating?.let { "★ %.1f".format(it) } ?: "New driver"
                Text("$rating · ${driver.completedRides} trips", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
            }
            driver.plateNumber?.let { Text(it, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = colors.onSurface) }
        }
    }
}

@Composable
private fun DriverAvatar(name: String?, photo: ByteArray?) {
    val colors = MaterialTheme.colorScheme
    val image = remember(photo) { photo?.let(::decodeAvatar) }
    if (image != null) {
        Image(image, "Driver's photo", contentScale = ContentScale.Crop, modifier = Modifier.size(56.dp).clip(CircleShape))
    } else {
        Box(Modifier.size(56.dp).clip(CircleShape).background(colors.primaryContainer), contentAlignment = Alignment.Center) {
            Text(name?.firstOrNull()?.uppercase() ?: "?", style = MaterialTheme.typography.titleLarge, color = colors.onPrimaryContainer)
        }
    }
}

/** Samples the selfie down, since a phone camera's full size would waste memory on a small circle. */
private fun decodeAvatar(bytes: ByteArray) = runCatching {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    var sample = 1
    while (bounds.outWidth / (sample * 2) >= AVATAR_PX && bounds.outHeight / (sample * 2) >= AVATAR_PX) sample *= 2
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
}.getOrNull()

private const val AVATAR_PX = 256

@Composable
private fun TripActions(ride: Ride, busy: Boolean, onCancel: () -> Unit, onDone: () -> Unit, onRetry: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        when {
            RideStatus.canCancel(ride.status) -> OutlinedButton(onClick = onCancel, enabled = !busy, modifier = Modifier.fillMaxWidth().height(52.dp)) { Text("Cancel ride") }
            ride.status == RideStatus.NO_DRIVERS -> {
                AuthPrimaryButton("Try again", enabled = true, busy = false, onClick = onRetry)
                TextButton(onClick = onDone, modifier = Modifier.fillMaxWidth()) { Text("Back to home") }
            }
            ride.status == RideStatus.CANCELLED -> AuthPrimaryButton("Done", enabled = true, busy = false, onClick = onDone)
        }
    }
}
