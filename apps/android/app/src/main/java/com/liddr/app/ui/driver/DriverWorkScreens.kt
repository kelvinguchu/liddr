package com.liddr.app.ui.driver

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.coroutines.launch
import com.liddr.app.data.Coordinates
import com.liddr.app.data.Delivery
import com.liddr.app.data.Offer
import com.liddr.app.data.Ride
import com.liddr.app.data.RideStatus
import com.liddr.app.data.SharedRide
import com.liddr.app.ui.booking.BodyText
import com.liddr.app.ui.booking.Heading
import com.liddr.app.ui.booking.Page
import com.liddr.app.ui.booking.TripMap
import com.liddr.app.ui.booking.mapsEnabled
import com.liddr.app.ui.booking.kilometres
import com.liddr.app.ui.booking.money
import com.liddr.app.ui.launch.AuthError
import com.liddr.app.ui.launch.AuthPrimaryButton
import com.liddr.app.ui.launch.AuthProgress
import com.liddr.app.ui.launch.LiddrLogo

@Composable
internal fun DriverHomeScreen(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit) {
    val context = LocalContext.current
    val online = state.profile?.isOnline == true
    var refused by rememberSaveable { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        if (results[Manifest.permission.ACCESS_FINE_LOCATION] == true || results[Manifest.permission.ACCESS_COARSE_LOCATION] == true) viewModel.goOnline() else refused = true
    }
    Page {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            LiddrLogo(Modifier.width(120.dp))
            TextButton(onClick = onAccount) { Text("Account") }
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Spacer(Modifier.height(20.dp))
            Heading(if (online) "You're online" else "You're offline")
            BodyText(if (online) "Waiting for trips near you. Keep Liddr open to see offers." else "Go online to start getting trips.")
            state.earnings?.let { earnings ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    EarningsCard("Today", earnings.today.totalKes, earnings.today.trips, Modifier.weight(1f))
                    EarningsCard("This week", earnings.thisWeek.totalKes, earnings.thisWeek.trips, Modifier.weight(1f))
                }
            }
            state.offers.forEach { OfferCard(it, state.busy, viewModel) }
            AuthError(state.error)
            if (refused) BodyText("Liddr needs your location to send you trips. Turn it on in Settings.")
        }
        if (online) {
            OutlinedButton(onClick = viewModel::goOffline, enabled = !state.busy, modifier = Modifier.fillMaxWidth().height(52.dp)) { Text("Go offline") }
        } else {
            AuthPrimaryButton("Go online", enabled = !state.busy, busy = state.busy) {
                if (hasLocation(context)) {
                    viewModel.goOnline()
                } else {
                    val wanted = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) wanted += Manifest.permission.POST_NOTIFICATIONS
                    ask.launch(wanted.toTypedArray())
                }
            }
        }
    }
}

private fun hasLocation(context: Context) =
    ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

@Composable
private fun EarningsCard(title: String, kes: Int, trips: Int, modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    Surface(shape = RoundedCornerShape(16.dp), color = colors.surface, border = BorderStroke(1.dp, colors.outlineVariant), modifier = modifier) {
        Column(Modifier.padding(14.dp)) {
            Text(title, style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant)
            Text(money(kes), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = colors.onSurface)
            Text(if (trips == 1) "1 trip" else "$trips trips", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
        }
    }
}

@Composable
private fun OfferCard(offer: Offer, busy: Boolean, viewModel: DriverViewModel) {
    val colors = MaterialTheme.colorScheme
    Surface(shape = RoundedCornerShape(16.dp), color = colors.surface, border = BorderStroke(2.dp, colors.primary), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("New trip · ${money(offer.fareKes)}", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = colors.onSurface)
            val rating = offer.riderRating?.let { " · Rider ★ %.1f".format(it) }.orEmpty()
            Text("Pickup ${kilometres(offer.distanceToPickupM)} away$rating", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = { viewModel.reject(offer) }, enabled = !busy, modifier = Modifier.weight(1f)) { Text("Decline") }
                Button(onClick = { viewModel.accept(offer) }, enabled = !busy, modifier = Modifier.weight(1f)) { Text("Accept") }
            }
        }
    }
}

private val cancelBeforeStart = listOf(
    "cannot_contact_rider" to "I can't reach the rider",
    "vehicle_issue" to "My vehicle has a problem",
    "safety_concern" to "I feel unsafe",
    "emergency" to "I have an emergency",
)

private val cancelDuringTrip = cancelBeforeStart.drop(1)

private fun openNavigation(context: Context, target: Coordinates) {
    val turnByTurn = Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=${target.lat},${target.lng}"))
    try {
        context.startActivity(turnByTurn)
    } catch (e: ActivityNotFoundException) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("geo:${target.lat},${target.lng}?q=${target.lat},${target.lng}")))
        } catch (none: ActivityNotFoundException) {
            // No maps app on this phone. The trip continues without directions.
        }
    }
}

private fun memberAction(status: String): Pair<String, String>? = when (status) {
    // Reaching a pickup moves a passenger to pickup_pending, meaning the driver is waiting for them.
    "requested", "assigned" -> "arrive-pickup" to "I'm at the pickup"
    "pickup_pending" -> "picked-up" to "Picked up"
    "picked_up" -> "dropped-off" to "Dropped off"
    else -> null
}

/** States are worded differently from the buttons, so a driver never mistakes one for the other. */
private fun memberState(status: String) = when (status) {
    "requested", "assigned" -> "Not collected yet"
    "pickup_pending" -> "Waiting at pickup"
    "picked_up" -> "On board"
    "dropped_off" -> "Arrived"
    "no_show" -> "Didn't come"
    "cancelled" -> "Left the trip"
    else -> status
}

/** The passengers of a shared trip, in the order the driver reaches them. */
@Composable
private fun SharedStops(shared: SharedRide, busy: Boolean, viewModel: DriverViewModel, context: Context) {
    val colors = MaterialTheme.colorScheme
    Surface(shape = RoundedCornerShape(16.dp), color = colors.surface, border = BorderStroke(1.dp, colors.outlineVariant), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Shared trip · ${shared.members.count { it.status !in setOf("cancelled", "no_show") }} passengers", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = colors.onSurface)
            shared.members.forEachIndexed { index, member ->
                val action = memberAction(member.status)
                val stop = shared.stops.firstOrNull { it.memberId == member.id && it.kind == (if (member.status == "picked_up") "dropoff" else "pickup") }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Passenger ${index + 1}", style = MaterialTheme.typography.bodyMedium, color = colors.onSurface)
                        Text(memberState(member.status), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                    }
                    stop?.let { TextButton(onClick = { openNavigation(context, it.point) }) { Text("Directions") } }
                    if (action != null) TextButton(onClick = { viewModel.memberStep(member.id, action.first) }, enabled = !busy) { Text(action.second) }
                    if (member.status == "pickup_pending") TextButton(onClick = { viewModel.memberStep(member.id, "no-show") }, enabled = !busy) { Text("No-show") }
                }
            }
        }
    }
}

@Composable
private fun DeliveryPanel(delivery: Delivery, context: Context) {
    val colors = MaterialTheme.colorScheme
    Surface(shape = RoundedCornerShape(16.dp), color = colors.surface, border = BorderStroke(1.dp, colors.outlineVariant), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Package: ${delivery.itemDescription}", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = colors.onSurface)
            Text("${delivery.itemSize.replaceFirstChar(Char::uppercase)} · from ${delivery.senderName} to ${delivery.recipientName}", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
            delivery.specialInstructions?.let { Text("Note: $it", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant) }
            if (delivery.dropoffProofAt != null && delivery.confirmedAt == null) {
                Text("Waiting for the recipient to confirm. You can complete 10 minutes after your delivery photo.", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
            }
            delivery.recipientPhone?.let { phone ->
                TextButton(onClick = {
                    runCatching { context.startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:+$phone"))) }
                }) { Text("Call ${delivery.recipientName}") }
            }
        }
    }
}

private data class NextStep(val title: String, val button: String, val action: String)

private fun nextStep(status: String) = when (status) {
    RideStatus.ACCEPTED -> NextStep("Head to the pickup", "I'm on my way", "arriving")
    RideStatus.DRIVER_ARRIVING -> NextStep("Head to the pickup", "I've arrived", "arrived")
    RideStatus.ARRIVED -> NextStep("Wait for your rider", "Start trip", "start")
    RideStatus.IN_PROGRESS -> NextStep("Take your rider to the destination", "Complete trip", "complete")
    else -> null
}

@Composable
internal fun DriverTripScreen(state: DriverUiState, viewModel: DriverViewModel) {
    val ride = state.ride ?: return
    val context = LocalContext.current
    val delivery = state.delivery
    val needsPhoto = when {
        delivery == null -> null
        ride.status == RideStatus.ARRIVED && delivery.pickupProofAt == null -> "pickup"
        ride.status == RideStatus.IN_PROGRESS && delivery.dropoffProofAt == null -> "dropoff"
        else -> null
    }
    val step = nextStep(ride.status)
    val scope = rememberCoroutineScope()
    var captureUri by rememberSaveable { mutableStateOf<String?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        val uri = captureUri
        val kind = needsPhoto
        if (saved && uri != null && kind != null) {
            scope.launch {
                val file = readDocument(context, Uri.parse(uri))
                if (file == null) viewModel.reportError("We couldn't read that photo. Please take it again.") else viewModel.uploadProof(kind, file.bytes)
            }
        }
    }
    var askPayment by rememberSaveable { mutableStateOf(false) }
    var askCancel by rememberSaveable { mutableStateOf(false) }
    Page {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            Spacer(Modifier.height(if (mapsEnabled) 8.dp else 40.dp))
            if (step != null) TripMap(ride.pickup, ride.dropoff, null, null)
            if (mapsEnabled) Spacer(Modifier.height(12.dp))
            Heading(step?.title ?: "This trip was cancelled")
            Spacer(Modifier.height(6.dp))
            BodyText(if (step != null) "Fare ${money(ride.fareKes)}, paid to you directly." else "You can go back to waiting for trips.")
            if (state.reconnecting) Text("Reconnecting…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(18.dp))
            delivery?.let { DeliveryPanel(it, context) }
            state.shared?.let { SharedStops(it, state.busy, viewModel, context) }
            ride.rider?.takeIf { delivery == null }?.let { rider ->
                Text(rider.name ?: "Your rider", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onBackground)
                rider.rating?.let { Text("★ %.1f".format(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            AuthError(state.error)
        }
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (step == null) {
                AuthPrimaryButton("Done", enabled = true, busy = false, onClick = viewModel::leaveTrip)
                return@Column
            }
            val target = if (ride.status == RideStatus.IN_PROGRESS) ride.dropoff else ride.pickup
            OutlinedButton(onClick = { openNavigation(context, target) }, modifier = Modifier.fillMaxWidth().height(48.dp)) { Text("Open directions") }
            if (needsPhoto != null) {
                AuthPrimaryButton(if (needsPhoto == "pickup") "Photograph the package" else "Photograph the delivered package", enabled = !state.busy, busy = state.busy) {
                    val file = File(File(context.cacheDir, "captures").apply { mkdirs() }, "proof.jpg")
                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                    captureUri = uri.toString()
                    camera.launch(uri)
                }
            } else {
                AuthPrimaryButton(if (delivery != null && step.action == "complete") "Complete delivery" else step.button, enabled = !state.busy, busy = state.busy) {
                    if (step.action == "complete") askPayment = true else viewModel.advance(step.action)
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = { askCancel = true }, enabled = !state.busy) { Text("Cancel trip") }
                if (ride.status == RideStatus.ARRIVED) TextButton(onClick = { viewModel.advance("no-show") }, enabled = !state.busy) { Text("Rider didn't come") }
            }
        }
    }
    if (askPayment) {
        AlertDialog(
            onDismissRequest = { askPayment = false },
            containerColor = MaterialTheme.colorScheme.surface,
            title = { Text("How did the rider pay?") },
            text = { Text("Collect ${money(ride.fareKes)} from your rider.") },
            confirmButton = {
                TextButton(onClick = {
                    askPayment = false
                    viewModel.complete("mpesa_direct")
                }) { Text("M-Pesa") }
            },
            dismissButton = {
                TextButton(onClick = {
                    askPayment = false
                    viewModel.complete("cash_direct")
                }) { Text("Cash") }
            },
        )
    }
    if (askCancel) {
        AlertDialog(
            onDismissRequest = { askCancel = false },
            containerColor = MaterialTheme.colorScheme.surface,
            title = { Text("Why are you cancelling?") },
            text = {
                Column {
                    Text("Repeated cancellations can suspend your account.", style = MaterialTheme.typography.bodySmall)
                    (if (ride.status == RideStatus.IN_PROGRESS) cancelDuringTrip else cancelBeforeStart).forEach { (code, label) ->
                        TextButton(onClick = {
                            askCancel = false
                            viewModel.cancel(code)
                        }, modifier = Modifier.fillMaxWidth()) { Text(label) }
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { askCancel = false }) { Text("Keep trip") } },
        )
    }
}
