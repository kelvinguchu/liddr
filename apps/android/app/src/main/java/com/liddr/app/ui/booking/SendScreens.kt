package com.liddr.app.ui.booking

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.liddr.app.data.Delivery
import com.liddr.app.data.DeliveryRequest
import com.liddr.app.data.Ride
import com.liddr.app.data.RideStatus
import com.liddr.app.ui.launch.AuthError
import com.liddr.app.ui.launch.AuthPrimaryButton

private val sizes = listOf("small" to "Small · fits a backpack", "medium" to "Medium · box up to 10 kg", "large" to "Large · up to 30 kg")

/** Who pays and when. A recipient can only pay once the package arrives. */
private val payments = listOf(
    Triple("sender_before", "I'll pay at pickup", "sender" to "before"),
    Triple("sender_after", "I'll pay on delivery", "sender" to "after"),
    Triple("recipient_after", "Recipient pays on delivery", "recipient" to "after"),
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun SendDetailsScreen(state: BookingUiState, viewModel: BookingViewModel) {
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

    Page {
        TextButton(onClick = viewModel::back) { Text("Back") }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Heading("Send a package")
            BodyText("To ${state.dropoff?.title.orEmpty()}")
            Field(sender, { sender = it }, "Your name", KeyboardCapitalization.Words)
            Field(recipient, { recipient = it }, "Recipient's name", KeyboardCapitalization.Words)
            Field(phone, { phone = it }, "Recipient's phone", keyboard = KeyboardType.Phone)
            Field(item, { item = it }, "What are you sending?", KeyboardCapitalization.Sentences)
            Text("Size", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onBackground)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                sizes.forEach { (code, label) -> FilterChip(selected = size == code, onClick = { size = code }, label = { Text(label) }) }
            }
            Text("Payment", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onBackground)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                payments.forEach { (code, label, _) -> FilterChip(selected = payment == code, onClick = { payment = code }, label = { Text(label) }) }
            }
            Field(notes, { notes = it }, "Instructions for the driver (optional)", KeyboardCapitalization.Sentences)
            BodyText("Liddr isn't liable for lost, damaged or stolen items. The driver photographs the package at pickup and delivery.")
            if (state.needsAcknowledgement) {
                Row(Modifier.toggleable(value = acknowledged, role = Role.Checkbox, onValueChange = { acknowledged = it }), verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = acknowledged, onCheckedChange = null)
                    Spacer(Modifier.width(10.dp))
                    Text("I accept responsibility for this item", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onBackground)
                }
            }
        }
        // Outside the scrolling form, so a refusal is visible next to the button that caused it.
        AuthError(state.error)
        Spacer(Modifier.height(8.dp))
        AuthPrimaryButton("Book Send", enabled = ready, busy = state.busy) {
            val (payer, timing) = payments.first { it.first == payment }.third
            viewModel.sendPackage(
                DeliveryRequest(
                    quoteId = "", senderName = sender.trim(), recipientName = recipient.trim(), recipientPhone = phone.trim(),
                    itemDescription = item.trim(), itemSize = size, payer = payer, paymentTiming = timing,
                    specialInstructions = notes.trim().takeIf(String::isNotEmpty), liabilityAcknowledged = acknowledged,
                ),
            )
        }
    }
}

@Composable
private fun Field(value: String, onChange: (String) -> Unit, label: String, caps: KeyboardCapitalization = KeyboardCapitalization.None, keyboard: KeyboardType = KeyboardType.Text) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(capitalization = caps, keyboardType = keyboard),
        modifier = Modifier.fillMaxWidth(),
    )
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
    Spacer(Modifier.height(16.dp))
    Surface(shape = RoundedCornerShape(16.dp), color = colors.surface, border = BorderStroke(2.dp, colors.primary), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("A package for you has arrived", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.onSurface)
            Text("${delivery.itemDescription} from ${delivery.senderName}", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
            AuthError(state.error)
            Spacer(Modifier.height(10.dp))
            AuthPrimaryButton("I received it", enabled = !state.busy, busy = state.busy, onClick = viewModel::confirm)
        }
    }
}
