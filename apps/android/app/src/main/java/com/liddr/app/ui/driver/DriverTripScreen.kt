package com.liddr.app.ui.driver

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.liddr.app.data.Coordinates
import com.liddr.app.data.Delivery
import com.liddr.app.data.Ride
import com.liddr.app.data.RideStatus
import com.liddr.app.data.SharedRide
import com.liddr.app.ui.booking.MapBackdrop
import com.liddr.app.ui.booking.ReasonSheet
import com.liddr.app.ui.booking.SheetTitle
import com.liddr.app.ui.booking.money
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.kit.MapSheet
import com.liddr.app.ui.kit.Overline
import com.liddr.app.ui.kit.Panel
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.SecondaryButton
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.SmallButton
import com.liddr.app.ui.kit.Space
import java.io.File
import kotlinx.coroutines.launch

private val cancelBeforeStart = listOf(
    "cannot_contact_rider" to "I can't reach the rider",
    "vehicle_issue" to "My vehicle has a problem",
    "safety_concern" to "I feel unsafe",
    "emergency" to "I have an emergency",
)

private val cancelDuringTrip = cancelBeforeStart.drop(1)

private data class NextStep(val title: String, val button: String, val action: String)

private fun nextStep(status: String) = when (status) {
    RideStatus.ACCEPTED -> NextStep("Head to the pickup", "I'm on my way", "arriving")
    RideStatus.DRIVER_ARRIVING -> NextStep("Head to the pickup", "I've arrived", "arrived")
    RideStatus.ARRIVED -> NextStep("Wait for your rider", "Start trip", "start")
    RideStatus.IN_PROGRESS -> NextStep("Take your rider to the destination", "Complete trip", "complete")
    else -> null
}

/** The trip on the map, and a sheet with the one next step held at the bottom. */
@Composable
internal fun DriverTripScreen(state: DriverUiState, viewModel: DriverViewModel) {
    val ride = state.ride ?: return
    val context = LocalContext.current
    val colors = MaterialTheme.colorScheme
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
    var sheet by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current

    Box(Modifier.fillMaxSize().background(colors.background)) {
        MapBackdrop(ride.pickup, ride.dropoff, null, null, with(density) { sheet.toDp() }, status = ride.status)
        MapSheet(Modifier.align(Alignment.BottomCenter).onSizeChanged { sheet = it.height }) {
            Column(Modifier.navigationBarsPadding()) {
                Column(Modifier.heightIn(max = SheetMax).verticalScroll(rememberScrollState()).padding(start = Gutter, end = Gutter, top = Space.lg)) {
                    SheetTitle(
                        step?.title ?: "This trip was cancelled",
                        if (step != null) "Fare ${money(ride.fareKes)}, paid to you directly" else "You can go back to waiting for trips.",
                    )
                    if (state.reconnecting) Text("Reconnecting…", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = Space.sm))
                    delivery?.let { DeliveryPanel(it, context) }
                    state.shared?.let { SharedStops(it, state.busy, viewModel, context) }
                    if (delivery == null) ride.rider?.let { RiderRow(it.name, it.rating) }
                }
                Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(Space.sm)) {
                    if (step == null) {
                        PrimaryButton("Done", onClick = viewModel::leaveTrip)
                        return@Column
                    }
                    if (needsPhoto != null) {
                        PrimaryButton(if (needsPhoto == "pickup") "Photograph the package" else "Photograph the delivered package", busy = state.busy, enabled = !state.busy, onClick = {
                            val file = File(File(context.cacheDir, "captures").apply { mkdirs() }, "proof.jpg")
                            val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                            captureUri = uri.toString()
                            camera.launch(uri)
                        })
                    } else {
                        PrimaryButton(if (delivery != null && step.action == "complete") "Complete delivery" else step.button, busy = state.busy, enabled = !state.busy, onClick = {
                            if (step.action == "complete") askPayment = true else viewModel.advance(step.action)
                        })
                    }
                    SecondaryButton("Open directions", onClick = { openNavigation(context, if (ride.status == RideStatus.IN_PROGRESS) ride.dropoff else ride.pickup) })
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        LinkButton("Cancel trip", { if (!state.busy) askCancel = true }, color = colors.error)
                        Spacer(Modifier.weight(1f))
                        if (ride.status == RideStatus.ARRIVED) LinkButton("Rider didn't come", { if (!state.busy) viewModel.advance("no-show") })
                    }
                }
            }
        }
    }
    if (askPayment) PaymentSheet(ride, onDismiss = { askPayment = false }) { mode ->
        askPayment = false
        viewModel.complete(mode)
    }
    if (askCancel) {
        ReasonSheet(
            title = "Why are you cancelling?",
            detail = "Repeated cancellations can suspend your account.",
            reasons = if (ride.status == RideStatus.IN_PROGRESS) cancelDuringTrip else cancelBeforeStart,
            keepLabel = "Keep trip",
            onDismiss = { askCancel = false },
        ) { code ->
            askCancel = false
            viewModel.cancel(code)
        }
    }
}

/** How the rider paid, asked once at the end so the trip's record is right. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PaymentSheet(ride: Ride, onDismiss: () -> Unit, onPaid: (String) -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surface, shape = Corners.sheet) {
        Column(Modifier.navigationBarsPadding().padding(start = Gutter, end = Gutter, bottom = Space.lg), verticalArrangement = Arrangement.spacedBy(Space.sm)) {
            SheetTitle("How did the rider pay?", "Collect ${money(ride.fareKes)} from your rider.")
            Spacer(Modifier.height(Space.sm))
            PrimaryButton("M-Pesa", onClick = { onPaid("mpesa_direct") })
            SecondaryButton("Cash", onClick = { onPaid("cash_direct") })
        }
    }
}

@Composable
private fun RiderRow(name: String?, rating: Double?) {
    val colors = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().padding(top = Space.lg), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(Size.touch).clip(CircleShape).background(colors.secondaryContainer), contentAlignment = Alignment.Center) {
            Text(name?.firstOrNull()?.uppercase() ?: "?", style = MaterialTheme.typography.titleLarge, color = colors.onSecondaryContainer)
        }
        Spacer(Modifier.width(Space.md))
        Column {
            Text(name ?: "Your rider", style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
            Text(rating?.let { "★ %.1f".format(it) } ?: "New rider", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
        }
    }
}

@Composable
private fun DeliveryPanel(delivery: Delivery, context: Context) {
    val colors = MaterialTheme.colorScheme
    Spacer(Modifier.height(Space.lg))
    Panel {
        Overline("Package")
        Text(delivery.itemDescription, style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
        Text("${delivery.itemSize.replaceFirstChar(Char::uppercase)} · from ${delivery.senderName} to ${delivery.recipientName}", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
        delivery.specialInstructions?.let { Text("Note: $it", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = Space.xs)) }
        if (delivery.dropoffProofAt != null && delivery.confirmedAt == null) {
            Text("Waiting for the recipient to confirm. You can complete 10 minutes after your delivery photo.", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = Space.xs))
        }
        delivery.recipientPhone?.let { phone ->
            LinkButton("Call ${delivery.recipientName}", { runCatching { context.startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:+$phone"))) } })
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
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SharedStops(shared: SharedRide, busy: Boolean, viewModel: DriverViewModel, context: Context) {
    val colors = MaterialTheme.colorScheme
    Spacer(Modifier.height(Space.lg))
    Panel {
        Overline("Shared trip · ${shared.members.count { it.status !in setOf("cancelled", "no_show") }} passengers")
        shared.members.forEachIndexed { index, member ->
            val action = memberAction(member.status)
            val stop = shared.stops.firstOrNull { it.memberId == member.id && it.kind == (if (member.status == "picked_up") "dropoff" else "pickup") }
            Text("Passenger ${index + 1}", style = MaterialTheme.typography.titleMedium, color = colors.onSurface, modifier = Modifier.padding(top = Space.md))
            Text(memberState(member.status), style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
            FlowRow(Modifier.padding(top = Space.xs), horizontalArrangement = Arrangement.spacedBy(Space.sm), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                if (action != null) SmallButton(action.second, { if (!busy) viewModel.memberStep(member.id, action.first) })
                stop?.let { LinkButton("Directions", { openNavigation(context, it.point) }) }
                if (member.status == "pickup_pending") LinkButton("No-show", { if (!busy) viewModel.memberStep(member.id, "no-show") }, color = colors.error)
            }
        }
    }
}

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

private val SheetMax = 520.dp
