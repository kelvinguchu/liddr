package com.liddr.app.ui.account

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.launch.AuthError
import com.liddr.app.ui.launch.AuthPrimaryButton
import com.liddr.app.ui.launch.AuthProgress
import com.liddr.app.ui.launch.LiddrLogo
import com.liddr.app.ui.launch.OnboardingBackground

/** Decides what a signed-in person sees: loading, a retry, their name, or their account. */
@Composable
fun SignedInRoot(
    viewModel: AccountViewModel,
    riderHome: @Composable (onAccount: () -> Unit) -> Unit,
    driverHome: @Composable (onAccount: () -> Unit) -> Unit,
) {
    val state by viewModel.ui.collectAsState()
    val me = state.me
    var showAccount by rememberSaveable { mutableStateOf(false) }
    var preferRider by rememberSaveable { mutableStateOf(false) }
    BackHandler(enabled = showAccount) { showAccount = false }
    when {
        state.loading -> Centered { AuthProgress() }
        me == null -> Centered {
            Text(state.error ?: "We couldn't load your account.", color = MaterialTheme.colorScheme.onBackground)
            Spacer(Modifier.height(12.dp))
            TextButton(onClick = viewModel::load) { Text("Try again") }
            TextButton(onClick = viewModel::signOut) { Text("Sign out") }
        }
        // Drivers give their legal name when they apply, so only riders are asked here.
        me.displayName == null && "driver" !in me.roles -> NameScreen(state, viewModel::saveName)
        !showAccount && "driver" in me.roles && !preferRider -> driverHome { showAccount = true }
        !showAccount && "rider" in me.roles -> riderHome { showAccount = true }
        else -> AccountScreen(
            state,
            onBack = { showAccount = false },
            // Someone who both rides and drives chooses which side of the app to use.
            switchLabel = if ("rider" in me.roles && "driver" in me.roles) (if (preferRider) "Switch to driving" else "Switch to riding") else null,
            onSwitch = {
                preferRider = !preferRider
                showAccount = false
            },
            onSignOut = viewModel::signOut,
            onDelete = viewModel::deleteAccount,
            onExport = viewModel::prepareExport,
            onExportSaved = viewModel::exportSaved,
            onExportFailed = viewModel::exportFailed,
        )
    }
}

@Composable
private fun Centered(content: @Composable () -> Unit) {
    OnboardingBackground {
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(28.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) { content() }
    }
}

@Composable
private fun NameScreen(state: AccountUiState, onSave: (String) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    OnboardingBackground {
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding().padding(horizontal = 28.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                Spacer(Modifier.height(48.dp))
                LiddrLogo()
                Spacer(Modifier.height(36.dp))
                Text("What's your name?", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onBackground)
                Spacer(Modifier.height(6.dp))
                Text("People you travel with will see it during a trip.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(28.dp))
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    singleLine = true,
                    isError = state.error != null,
                    readOnly = state.busy,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                    modifier = Modifier.fillMaxWidth(),
                )
                AuthError(state.error)
            }
            AuthPrimaryButton("Continue", enabled = name.trim().length >= 2 && !state.busy, busy = state.busy) { onSave(name) }
        }
    }
}

@Composable
private fun AccountScreen(
    state: AccountUiState,
    onBack: () -> Unit,
    switchLabel: String?,
    onSwitch: () -> Unit,
    onSignOut: () -> Unit,
    onDelete: () -> Unit,
    onExport: () -> Unit,
    onExportSaved: (Boolean) -> Unit,
    onExportFailed: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val pending = state.export
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri == null || pending == null) {
            onExportSaved(false)
            return@rememberLauncherForActivityResult
        }
        scope.launch {
            val written = withContext(Dispatchers.IO) {
                runCatching { context.contentResolver.openOutputStream(uri)?.use { it.write(pending.toByteArray()) } != null }.getOrDefault(false)
            }
            if (written) onExportSaved(true) else onExportFailed()
        }
    }
    LaunchedEffect(pending) { if (pending != null) save.launch("liddr-data.json") }
    var confirmDelete by rememberSaveable { mutableStateOf(false) }
    val me = state.me ?: return
    OnboardingBackground {
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = 28.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                TextButton(onClick = onBack) { Text("Back") }
                LiddrLogo()
                Spacer(Modifier.height(36.dp))
                Text(me.displayName.orEmpty(), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold, color = colors.onBackground)
                if (me.phone.isNotEmpty()) {
                    Spacer(Modifier.height(6.dp))
                    Text("+${me.phone}", style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
                }
                Spacer(Modifier.height(6.dp))
                Text(me.roles.joinToString { it.replaceFirstChar(Char::uppercase) }, style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
                AuthError(state.error)
                state.notice?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 10.dp)) }
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = onExport, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) { Text("Download my data") }
                if (switchLabel != null) OutlinedButton(onClick = onSwitch, modifier = Modifier.fillMaxWidth().height(52.dp)) { Text(switchLabel) }
                OutlinedButton(onClick = onSignOut, enabled = !state.busy, modifier = Modifier.fillMaxWidth().height(52.dp)) { Text("Sign out") }
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    TextButton(onClick = { confirmDelete = true }, enabled = !state.busy) { Text("Delete account", color = colors.error) }
                }
            }
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            containerColor = colors.surface,
            title = { Text("Delete your account?") },
            text = { Text("Your name, phone number and email are removed straight away. Trip and payment records are kept without them, as the law requires. This can't be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    onDelete()
                }) { Text("Delete", color = colors.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Keep account") } },
        )
    }
}
