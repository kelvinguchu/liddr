package com.liddr.app.ui.driver

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardCapitalization
import com.liddr.app.ui.booking.VehicleArt
import com.liddr.app.ui.booking.money
import com.liddr.app.ui.kit.FormField
import com.liddr.app.ui.kit.LiddrCard
import com.liddr.app.ui.kit.ListRow
import com.liddr.app.ui.kit.Panel
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.RowDivider
import com.liddr.app.ui.kit.SectionHeader
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.kit.Thumbnail
import com.liddr.app.ui.launch.AuthError
import com.liddr.app.ui.launch.AuthProgress
import compose.icons.TablerIcons
import compose.icons.tablericons.ChevronRight


@Composable
internal fun CategoryScreen(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit) {
    DriverPage(
        title = if (state.changingVehicle) "Change your vehicle" else "What do you drive?",
        onAccount = onAccount,
        body = "Your weekly subscription depends on your vehicle.",
        onBack = viewModel::back.takeIf { state.changingVehicle },
    ) {
        Spacer(Modifier.height(Space.xl))
        LiddrCard {
            state.categories.forEachIndexed { index, category ->
                if (index > 0) RowDivider(inset = false)
                ListRow(
                    category.label,
                    onClick = { viewModel.chooseCategory(category.slug) }.takeUnless { state.busy },
                    leading = { Thumbnail { VehicleArt(category.slug, Size.art) } },
                    trailing = { RowChevron() },
                )
            }
        }
    }
}

@Composable
internal fun VerificationScreen(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit) {
    val verification = state.verification ?: return
    val application = verification.application
    when (application?.status) {
        "pending", "under_review", "resubmission_required" -> DocumentsScreen(state, viewModel, onAccount)
        "suspended" -> DriverPage(title = "Your account is suspended", onAccount = onAccount, body = application.decisionReason ?: "Please contact Liddr support.")
        else -> ApplicationForm(state, viewModel, onAccount, application?.decisionReason.takeIf { application?.status == "rejected" })
    }
}

@Composable
private fun ApplicationForm(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit, rejectedBecause: String?) {
    val colors = MaterialTheme.colorScheme
    var fullName by rememberSaveable { mutableStateOf("") }
    var plate by rememberSaveable { mutableStateOf("") }
    var consent by rememberSaveable { mutableStateOf(false) }
    DriverPage(
        title = "Get verified to drive",
        onAccount = onAccount,
        onBack = viewModel::back,
        body = rejectedBecause?.let { "Your last application was rejected: $it" } ?: "Your details must match your ID and logbook.",
        bottom = {
            AuthError(state.error)
            PrimaryButton("Continue", busy = state.busy, enabled = consent && fullName.trim().length >= 2 && plate.isNotBlank() && !state.busy, onClick = {
                viewModel.startApplication(plate, fullName)
            })
        },
    ) {
        Spacer(Modifier.height(Space.xl))
        FormField(fullName, { fullName = it }, "Full name on your ID", keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
        Spacer(Modifier.height(Space.md))
        FormField(plate, { plate = it }, "Number plate", keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters))
        Row(
            Modifier.fillMaxWidth().padding(top = Space.md).toggleable(value = consent, role = Role.Checkbox, onValueChange = { consent = it }).padding(vertical = Space.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Checkbox(checked = consent, onCheckedChange = null, colors = CheckboxDefaults.colors(checkedColor = colors.secondary))
            Spacer(Modifier.width(Space.md))
            Text("Riders on my trips can see my verification selfie as my photo.", style = MaterialTheme.typography.bodyMedium, color = colors.onSurface)
        }
    }
}

@Composable
internal fun RowChevron() {
    Icon(TablerIcons.ChevronRight, null, Modifier.size(Size.smallIcon), tint = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
internal fun SubscriptionScreen(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit) {
    val subscription = state.subscription ?: return
    val colors = MaterialTheme.colorScheme
    DriverPage(
        title = "Pay for this week",
        onAccount = onAccount,
        body = "${money(subscription.amountKes)} lets you drive all week and keep every shilling of every fare.",
        bottom = { PrimaryButton("Pay ${money(subscription.amountKes)} with M-Pesa", busy = state.busy, enabled = !state.busy && !state.paying, onClick = viewModel::pay) },
    ) {
        if (state.paying) {
            Spacer(Modifier.height(Space.xl))
            Panel(tint = colors.tertiaryContainer) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    AuthProgress()
                    Spacer(Modifier.width(Space.md))
                    Text("Check your phone and enter your M-Pesa PIN.", style = MaterialTheme.typography.bodyLarge, color = colors.onTertiaryContainer)
                }
            }
        }
        SectionHeader("Or pay by Paybill")
        LiddrCard {
            ListRow("Business number", trailing = { Text(subscription.paybillShortcode, style = MaterialTheme.typography.titleMedium, color = colors.onSurface) })
            RowDivider(inset = false)
            ListRow("Account number", trailing = { Text(subscription.reference, style = MaterialTheme.typography.titleMedium, color = colors.onSurface) })
        }
    }
}
