package com.liddr.app.ui.booking

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import com.liddr.app.data.Delivery
import com.liddr.app.data.DeliveryRequest
import com.liddr.app.data.Ride
import com.liddr.app.data.RideStatus
import com.liddr.app.ui.kit.ChoiceRow
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.kit.FormField
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.LiddrCard
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.RowDivider
import com.liddr.app.ui.kit.ScreenHeader
import com.liddr.app.ui.kit.SectionHeader
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.launch.AuthError
import compose.icons.TablerIcons
import compose.icons.tablericons.InfoCircle

/** Package sizes, with what each one fits. */
private val sizes = listOf(
    Triple("small", "Small", "Fits a backpack"),
    Triple("medium", "Medium", "A box up to 10 kg"),
    Triple("large", "Large", "Up to 30 kg"),
)

/** Who pays and when. A recipient can only pay once the package arrives. */
private val payments = listOf(
    Triple("sender_before", "I'll pay at pickup", "sender" to "before"),
    Triple("sender_after", "I'll pay on delivery", "sender" to "after"),
    Triple("recipient_after", "The recipient pays on delivery", "recipient" to "after"),
)

/** Who the package is for, what it is, and who pays: everything the driver needs. */
@Composable
internal fun SendDetailsScreen(state: BookingUiState, viewModel: BookingViewModel) {
    val colors = MaterialTheme.colorScheme
    var sender by rememberSaveable { mutableStateOf("") }
    var recipient by rememberSaveable { mutableStateOf("") }
    var phone by rememberSaveable { mutableStateOf("") }
    var item by rememberSaveable { mutableStateOf("") }
    var size by rememberSaveable { mutableStateOf("small") }
    var payment by rememberSaveable { mutableStateOf("sender_before") }
    var notes by rememberSaveable { mutableStateOf("") }
    var acknowledged by rememberSaveable { mutableStateOf(false) }
    val ready = sender.isNotBlank() && recipient.isNotBlank() && phone.isNotBlank() && item.isNotBlank() &&
        (!state.needsAcknowledgement || acknowledged) && !state.busy
    val words = KeyboardOptions(capitalization = KeyboardCapitalization.Words)
    val sentences = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences)

    Column(Modifier.fillMaxSize().background(colors.background).windowInsetsPadding(WindowInsets.safeDrawing).imePadding()) {
        ScreenHeader("Send a package", onBack = viewModel::back)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Gutter)) {
            Text("To ${state.dropoff?.title.orEmpty()}", style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)

            SectionHeader("Who it's for")
            Column(verticalArrangement = Arrangement.spacedBy(Space.md)) {
                FormField(recipient, { recipient = it }, "Recipient's name", keyboardOptions = words)
                FormField(phone, { phone = it }, "Recipient's phone", keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone))
                FormField(sender, { sender = it }, "Your name", keyboardOptions = words)
            }

            SectionHeader("The package")
            FormField(item, { item = it }, "What are you sending?", keyboardOptions = sentences)
            Spacer(Modifier.height(Space.md))
            LiddrCard {
                sizes.forEachIndexed { index, (code, label, fits) ->
                    if (index > 0) RowDivider(inset = false)
                    ChoiceRow(label, size == code, { size = code }, supporting = fits)
                }
            }
            Spacer(Modifier.height(Space.md))
            FormField(notes, { notes = it }, "Instructions for the driver (optional)", keyboardOptions = sentences)

            SectionHeader("Payment")
            LiddrCard {
                payments.forEachIndexed { index, (code, label, _) ->
                    if (index > 0) RowDivider(inset = false)
                    ChoiceRow(label, payment == code, { payment = code })
                }
            }

            Row(Modifier.padding(top = Space.xl), verticalAlignment = Alignment.Top) {
                Icon(TablerIcons.InfoCircle, null, Modifier.size(Size.smallIcon), tint = colors.onSurfaceVariant)
                Spacer(Modifier.width(Space.md))
                Text(
                    "Liddr isn't liable for lost, damaged or stolen items. The driver photographs the package at pickup and delivery.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.onSurfaceVariant,
                )
            }
            if (state.needsAcknowledgement) {
                Row(
                    Modifier.fillMaxWidth().padding(top = Space.sm).toggleable(value = acknowledged, role = Role.Checkbox, onValueChange = { acknowledged = it }).height(Size.touch),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(checked = acknowledged, onCheckedChange = null, colors = CheckboxDefaults.colors(checkedColor = colors.secondary))
                    Spacer(Modifier.width(Space.md))
                    Text("I accept responsibility for this item", style = MaterialTheme.typography.bodyMedium, color = colors.onSurface)
                }
            }
            Spacer(Modifier.height(Space.lg))
        }
        Column(Modifier.padding(start = Gutter, end = Gutter, bottom = Space.lg)) {
            // Outside the scrolling form, so a refusal is visible next to the button that caused it.
            AuthError(state.error)
            Spacer(Modifier.height(Space.sm))
            PrimaryButton("Book Send", enabled = ready, busy = state.busy, onClick = {
                val (payer, timing) = payments.first { it.first == payment }.third
                viewModel.sendPackage(
                    DeliveryRequest(
                        quoteId = "", senderName = sender.trim(), recipientName = recipient.trim(), recipientPhone = phone.trim(),
                        itemDescription = item.trim(), itemSize = size, payer = payer, paymentTiming = timing,
                        specialInstructions = notes.trim().takeIf(String::isNotEmpty), liabilityAcknowledged = acknowledged,
                    ),
                )
            })
        }
    }
}

internal fun deliveryHeadline(status: String, delivery: Delivery) = when {
    status == RideStatus.SEARCHING -> "Finding a driver for your package"
    status in setOf(RideStatus.ACCEPTED, RideStatus.DRIVER_ARRIVING) -> "Your driver is coming to collect"
    status == RideStatus.ARRIVED -> "Your driver is at the pickup"
    status == RideStatus.IN_PROGRESS && delivery.dropoffProofAt != null && delivery.confirmedAt == null -> "Delivered. Waiting for ${delivery.recipientName} to confirm"
    status == RideStatus.IN_PROGRESS -> "Your package is on its way"
    status == RideStatus.COMPLETED -> "Your package was delivered"
    else -> headline(status)
}

@Composable
internal fun DeliveryDetail(ride: Ride, delivery: Delivery) {
    val pay = when {
        delivery.payer == "recipient" -> "${delivery.recipientName} pays the driver ${money(ride.fareKes)} on delivery."
        delivery.paymentTiming == "before" -> "Pay your driver ${money(ride.fareKes)} at pickup."
        else -> "Pay your driver ${money(ride.fareKes)} on delivery."
    }
    BodyText("${delivery.itemDescription} for ${delivery.recipientName}. $pay")
}

/** Shows a package waiting for this person to confirm they received it. */
@Composable
internal fun IncomingPackageCard(viewModel: IncomingViewModel) {
    val state by viewModel.ui.collectAsState()
    val delivery = state.delivery ?: return
    val colors = MaterialTheme.colorScheme
    Spacer(Modifier.height(Space.lg))
    Surface(shape = Corners.lg, color = colors.tertiaryContainer, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(Space.lg)) {
            Text("A package for you has arrived", style = MaterialTheme.typography.titleMedium, color = colors.onTertiaryContainer)
            Text("${delivery.itemDescription} from ${delivery.senderName}", style = MaterialTheme.typography.bodyMedium, color = colors.onTertiaryContainer)
            AuthError(state.error)
            Spacer(Modifier.height(Space.md))
            PrimaryButton("I received it", enabled = !state.busy, busy = state.busy, onClick = viewModel::confirm)
        }
    }
}
