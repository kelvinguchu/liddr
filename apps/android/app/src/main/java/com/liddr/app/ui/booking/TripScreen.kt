package com.liddr.app.ui.booking

import com.liddr.app.ui.kit.RouteNode
import com.liddr.app.ui.kit.Space
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.liddr.app.data.Ride
import com.liddr.app.data.RideStatus
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.kit.MapSheet
import com.liddr.app.ui.kit.Overline
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.kit.ListRow
import com.liddr.app.ui.kit.RowDivider
import com.liddr.app.ui.kit.SecondaryButton
import com.liddr.app.ui.kit.Size
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import compose.icons.TablerIcons
import compose.icons.tablericons.ChevronRight

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

/** Under a kilometre in metres, rounded to 50, so it reads like a street sign. */
internal fun nearby(metres: Int) = if (metres < 1000) "${(metres / 50).coerceAtLeast(1) * 50} m" else kilometres(metres)


/** The live trip: the map behind, and a sheet that changes with each step of the ride. */
@Composable
internal fun TripScreen(state: BookingUiState, viewModel: BookingViewModel) {
    val ride = state.ride ?: return
    val colors = MaterialTheme.colorScheme
    var askReason by rememberSaveable { mutableStateOf(false) }
    var flashing by rememberSaveable { mutableStateOf(false) }
    var sheet by remember { mutableStateOf(0) }
    val density = LocalDensity.current
    val pickupName = state.pickup?.title ?: "your pickup"
    val dropoffName = state.dropoff?.title ?: "your destination"

    Box(Modifier.fillMaxSize()) {
        MapBackdrop(ride.pickup, ride.dropoff, ride.driverLocation, state.tripRoute, with(density) { sheet.toDp() }, status = ride.status)
        MapSheet(Modifier.align(Alignment.BottomCenter).onSizeChanged { sheet = it.height }) {
            Column(Modifier.navigationBarsPadding()) {
                Column(Modifier.heightIn(max = SheetMax).verticalScroll(rememberScrollState()).padding(start = Gutter, end = Gutter, top = Space.lg, bottom = Space.lg)) {
                    val delivery = state.delivery
                    when {
                        delivery != null -> {
                            SheetTitle(deliveryHeadline(ride.status, delivery))
                            Spacer(Modifier.height(Space.xs))
                            DeliveryDetail(ride, delivery)
                            ride.driver?.let { DriverPlate(it, state.driverPhoto) }
                        }
                        ride.status == RideStatus.SEARCHING -> WaitingChecklist(ride, pickupName, state.selected)
                        ride.status == RideStatus.ACCEPTED || ride.status == RideStatus.DRIVER_ARRIVING -> DriverComing(ride, pickupName, state.driverPhoto)
                        ride.status == RideStatus.ARRIVED -> DriverHere(ride, state.driverPhoto) { flashing = true }
                        ride.status == RideStatus.IN_PROGRESS -> OnTheRide(ride, dropoffName, state.driverPhoto)
                        ride.status == RideStatus.COMPLETED -> Arrived(ride, dropoffName, state, viewModel)
                        else -> Ended(ride, viewModel)
                    }
                    if (state.reconnecting) Text("Reconnecting…", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = Space.sm))
                }
                if (RideStatus.isActive(ride.status)) TicketStub(ride, dropoffName, state.busy, onCancel = {
                    if (ride.status == RideStatus.SEARCHING) viewModel.cancel("rider_changed_mind") else askReason = true
                })
            }
        }
    }
    if (flashing) ride.driver?.let { FlashScreen(it) { flashing = false } }
    if (askReason) {
        ReasonSheet(
            title = "Why are you cancelling?",
            detail = "Repeated cancellations can pause your bookings, unless the driver was at fault.",
            reasons = cancelReasons,
            keepLabel = "Keep my ride",
            onDismiss = { askReason = false },
        ) { code ->
            askReason = false
            viewModel.cancel(code)
        }
    }
}

/** Why someone is cancelling, one tap per reason, with keeping the trip as the easy way out. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ReasonSheet(title: String, detail: String, reasons: List<Pair<String, String>>, keepLabel: String, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    val colors = MaterialTheme.colorScheme
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = colors.surface, shape = Corners.sheet) {
        Column(Modifier.navigationBarsPadding().padding(bottom = Space.lg)) {
            Column(Modifier.padding(horizontal = Gutter)) { SheetTitle(title, detail) }
            Spacer(Modifier.height(Space.sm))
            reasons.forEachIndexed { index, (code, label) ->
                if (index > 0) RowDivider(inset = false)
                ListRow(label, onClick = { onPick(code) }, trailing = {
                    Icon(TablerIcons.ChevronRight, null, Modifier.size(Size.smallIcon), tint = colors.onSurfaceVariant)
                })
            }
            Spacer(Modifier.height(Space.lg))
            SecondaryButton(keepLabel, onClick = onDismiss, modifier = Modifier.padding(horizontal = Gutter))
        }
    }
}

/** Below the perforation: where you're going and what it costs, for the whole trip. */
@Composable
private fun TicketStub(ride: Ride, dropoffName: String, busy: Boolean, onCancel: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    HorizontalDivider(color = colors.outlineVariant)
    val cancellable = RideStatus.canCancel(ride.status) && !busy
    Row(Modifier.fillMaxWidth().padding(start = Gutter, end = if (cancellable) Space.sm else Gutter, top = Space.md, bottom = Space.md), verticalAlignment = Alignment.CenterVertically) {
        RouteNode(pickup = false)
        Spacer(Modifier.width(Space.md))
        Column(Modifier.weight(1f)) {
            Overline("To")
            Text(dropoffName, style = MaterialTheme.typography.titleMedium, color = colors.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(Space.lg))
        Column(horizontalAlignment = Alignment.End) {
            Overline(if (ride.status == RideStatus.IN_PROGRESS) "Pay at the end" else "Fare")
            Text(money(ride.fareKes), style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
        }
        if (cancellable) {
            Spacer(Modifier.width(Space.xs))
            LinkButton("Cancel", onCancel, color = colors.error)
        }
    }
}

/** No driver came, or the ride was cancelled: say so and offer the next step. */
@Composable
private fun ColumnScope.Ended(ride: Ride, viewModel: BookingViewModel) {
    SheetTitle(headline(ride.status), if (ride.status == RideStatus.NO_DRIVERS) "Nobody nearby could take this trip. You weren't charged." else "You weren't charged.")
    Spacer(Modifier.height(Space.lg))
    if (ride.status == RideStatus.NO_DRIVERS) {
        PrimaryButton("Try again", onClick = viewModel::tryAgain)
        LinkButton("Back to home", viewModel::finishTrip, Modifier.align(Alignment.CenterHorizontally))
    } else {
        PrimaryButton("Done", onClick = viewModel::finishTrip)
    }
}

private val SheetMax = 560.dp
