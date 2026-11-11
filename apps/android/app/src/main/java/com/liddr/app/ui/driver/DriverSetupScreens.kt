package com.liddr.app.ui.driver

import android.net.Uri
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.liddr.app.data.Requirement
import com.liddr.app.ui.booking.BodyText
import com.liddr.app.ui.booking.Heading
import com.liddr.app.ui.booking.Page
import com.liddr.app.ui.booking.money
import com.liddr.app.ui.launch.AuthError
import com.liddr.app.ui.launch.AuthPrimaryButton
import com.liddr.app.ui.launch.AuthProgress
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.launch

private const val SELFIE = "driver_selfie_liveness"
private const val YEAR_MS = 365L * 24 * 60 * 60 * 1000

@Composable
private fun SetupHeader(onAccount: () -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { TextButton(onClick = onAccount) { Text("Account") } }
}

@Composable
internal fun CategoryScreen(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Page {
        SetupHeader(onAccount)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Heading("What do you drive?")
            BodyText("Your weekly subscription depends on your vehicle.")
            Spacer(Modifier.height(4.dp))
            state.categories.forEach { category ->
                Surface(
                    onClick = { viewModel.chooseCategory(category.slug) },
                    enabled = !state.busy,
                    shape = RoundedCornerShape(16.dp),
                    color = colors.surface,
                    border = BorderStroke(1.dp, colors.outlineVariant),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(category.label, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.onSurface, modifier = Modifier.padding(18.dp))
                }
            }
            AuthError(state.error)
        }
    }
}

@Composable
internal fun VerificationScreen(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit) {
    val verification = state.verification ?: return
    val application = verification.application
    when (application?.status) {
        "pending", "under_review", "resubmission_required" -> DocumentsScreen(state, viewModel, onAccount)
        "suspended" -> Page {
            SetupHeader(onAccount)
            Heading("Your account is suspended")
            BodyText(application.decisionReason ?: "Please contact Liddr support.")
        }
        else -> ApplicationForm(state, viewModel, onAccount, application?.decisionReason.takeIf { application?.status == "rejected" })
    }
}

@Composable
private fun ApplicationForm(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit, rejectedBecause: String?) {
    var fullName by rememberSaveable { mutableStateOf("") }
    var plate by rememberSaveable { mutableStateOf("") }
    var consent by rememberSaveable { mutableStateOf(false) }
    Page {
        SetupHeader(onAccount)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            Heading("Get verified to drive")
            if (rejectedBecause != null) {
                Spacer(Modifier.height(6.dp))
                BodyText("Your last application was rejected: $rejectedBecause")
            }
            Spacer(Modifier.height(20.dp))
            OutlinedTextField(
                value = fullName,
                onValueChange = { fullName = it },
                label = { Text("Full name on your ID") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = plate,
                onValueChange = { plate = it },
                label = { Text("Number plate") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            Row(Modifier.toggleable(value = consent, role = Role.Checkbox, onValueChange = { consent = it }), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = consent, onCheckedChange = null)
                Spacer(Modifier.width(10.dp))
                Text(
                    "I agree that riders on my trips can see my verification selfie as my photo.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onBackground,
                )
            }
            AuthError(state.error)
        }
        AuthPrimaryButton("Continue", enabled = consent && fullName.trim().length >= 2 && plate.isNotBlank() && !state.busy, busy = state.busy) {
            viewModel.startApplication(plate, fullName)
        }
    }
}

internal fun documentStatus(requirement: Requirement): String {
    val document = requirement.document ?: return "Not uploaded"
    return when (document.status) {
        "scanning" -> "Checking your file"
        "pending_review" -> "Waiting for review"
        "validated" -> "Approved"
        "rejected" -> "Rejected: ${document.rejectionReason ?: "please upload it again"}"
        "resubmission_required" -> "Upload again: ${document.rejectionReason ?: "please send a clearer copy"}"
        "expired" -> "Expired. Upload a new one"
        else -> "Uploaded"
    }
}

internal fun canUpload(requirement: Requirement): Boolean =
    requirement.document?.status.let { it == null || it in setOf("rejected", "resubmission_required", "expired") }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DocumentsScreen(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val requirements = state.verification?.requirements.orEmpty()
    var choosing by rememberSaveable { mutableStateOf<String?>(null) }
    var askExpiry by rememberSaveable { mutableStateOf(false) }
    var expiresOn by rememberSaveable { mutableStateOf<String?>(null) }
    var captureUri by rememberSaveable { mutableStateOf<String?>(null) }
    var showSource by rememberSaveable { mutableStateOf(false) }

    fun send(uri: Uri) {
        val type = choosing ?: return
        val expiry = expiresOn
        scope.launch {
            val file = readDocument(context, uri)
            if (file == null) viewModel.reportError("We couldn't read that file. Please try another.") else viewModel.upload(type, file.contentType, file.bytes, expiry)
        }
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved -> if (saved) captureUri?.let { send(Uri.parse(it)) } }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> uri?.let(::send) }

    Page {
        SetupHeader(onAccount)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Heading("Your documents")
            val waiting = requirements.isNotEmpty() && requirements.none(::canUpload)
            BodyText(if (waiting) "Everything is in. We'll review your documents and let you know." else "Upload each one. Photos must be clear and show the whole document.")
            AuthError(state.error)
            requirements.forEach { requirement ->
                DocumentRow(requirement, state.uploading == requirement.documentType, enabled = state.uploading == null && canUpload(requirement)) {
                    choosing = requirement.documentType
                    expiresOn = null
                    if (requirement.requiresExpiry) askExpiry = true else showSource = true
                }
            }
        }
    }

    if (askExpiry) {
        val now = System.currentTimeMillis()
        val picked = rememberDatePickerState(
            initialSelectedDateMillis = now + YEAR_MS,
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long) = utcTimeMillis > now
            },
        )
        DatePickerDialog(
            onDismissRequest = { askExpiry = false },
            confirmButton = {
                TextButton(onClick = {
                    expiresOn = picked.selectedDateMillis?.let { millis ->
                        SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(millis))
                    }
                    askExpiry = false
                    showSource = true
                }) { Text("Next") }
            },
            dismissButton = { TextButton(onClick = { askExpiry = false }) { Text("Cancel") } },
        ) { DatePicker(state = picked, title = { Text("When does it expire?", Modifier.padding(start = 24.dp, top = 16.dp)) }) }
    }

    if (showSource) {
        val selfie = choosing == SELFIE
        AlertDialog(
            onDismissRequest = { showSource = false },
            containerColor = MaterialTheme.colorScheme.surface,
            title = { Text(if (selfie) "Take a selfie" else "Add this document") },
            text = { if (selfie) Text("This photo is also what riders will see. Face the camera in good light.") },
            confirmButton = {
                TextButton(onClick = {
                    showSource = false
                    val file = File(File(context.cacheDir, "captures").apply { mkdirs() }, "capture.jpg")
                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                    captureUri = uri.toString()
                    camera.launch(uri)
                }) { Text("Take photo") }
            },
            dismissButton = {
                if (!selfie) {
                    TextButton(onClick = {
                        showSource = false
                        picker.launch("*/*")
                    }) { Text("Choose a file") }
                }
            },
        )
    }
}

@Composable
private fun DocumentRow(requirement: Requirement, uploading: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(onClick = onClick, enabled = enabled, shape = RoundedCornerShape(14.dp), color = colors.surface, border = BorderStroke(1.dp, colors.outlineVariant), modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(requirement.label, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = colors.onSurface)
                Text(if (uploading) "Uploading…" else documentStatus(requirement), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
            }
            if (uploading) {
                Spacer(Modifier.width(8.dp))
                AuthProgress()
            }
        }
    }
}

@Composable
internal fun SubscriptionScreen(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit) {
    val subscription = state.subscription ?: return
    Page {
        SetupHeader(onAccount)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            Heading("Pay for this week")
            Spacer(Modifier.height(6.dp))
            BodyText("${money(subscription.amountKes)} lets you drive all week and keep 100% of every fare.")
            Spacer(Modifier.height(18.dp))
            if (state.paying) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    AuthProgress()
                    Spacer(Modifier.width(12.dp))
                    BodyText("Check your phone and enter your M-Pesa PIN.")
                }
                Spacer(Modifier.height(18.dp))
            }
            Text("Or pay by Paybill", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onBackground)
            BodyText("Business number ${subscription.paybillShortcode}")
            BodyText("Account number ${subscription.reference}")
            AuthError(state.error)
        }
        AuthPrimaryButton("Pay with M-Pesa", enabled = !state.busy && !state.paying, busy = state.busy, onClick = viewModel::pay)
    }
}
