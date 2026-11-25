package com.liddr.app.ui.account

import com.liddr.app.ui.kit.EmptyState
import com.liddr.app.ui.kit.LinkButton
import compose.icons.TablerIcons
import compose.icons.tablericons.WifiOff

import com.liddr.app.ui.kit.Size
import androidx.compose.foundation.layout.Row
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.theme.ThemeSetting
import androidx.compose.foundation.shape.RoundedCornerShape
import com.liddr.app.ui.kit.StepBar
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.Panel
import com.liddr.app.ui.kit.Overline
import com.liddr.app.ui.kit.Gutter
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
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
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
    theme: ThemeSetting,
    riderHome: @Composable (onAccount: () -> Unit) -> Unit,
    driverHome: @Composable (onAccount: () -> Unit) -> Unit,
) {
    val state by viewModel.ui.collectAsState()
    val me = state.me
    var showAccount by rememberSaveable { mutableStateOf(false) }
    var preferRider by rememberSaveable { mutableStateOf(false) }
    BackHandler(enabled = showAccount) { showAccount = false }
    // Account covers the rider or driver side, so each side keeps its tab and scroll for Back.
    val sides = rememberSaveableStateHolder()
    when {
        state.loading -> Centered { AuthProgress() }
        me == null -> Centered {
            EmptyState(TablerIcons.WifiOff, "We couldn't load your account", state.error ?: "Check your connection, then try again.", actionLabel = "Try again", onAction = viewModel::load)
            LinkButton("Sign out", viewModel::signOut)
        }
        // Drivers give their legal name when they apply, so only riders are asked here.
        me.displayName == null && "driver" !in me.roles -> NameScreen(state, viewModel::saveName)
        !showAccount && "driver" in me.roles && !preferRider -> sides.SaveableStateProvider("driver") { driverHome { showAccount = true } }
        !showAccount && "rider" in me.roles -> sides.SaveableStateProvider("rider") { riderHome { showAccount = true } }
        else -> AccountScreen(
            state,
            theme = theme,
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
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(Space.xl),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) { content() }
    }
}

@Composable
private fun NameScreen(state: AccountUiState, onSave: (String) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    val colors = MaterialTheme.colorScheme
    val ready = name.trim().length >= 2 && !state.busy
    OnboardingBackground {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding().padding(horizontal = Gutter)) {
            // Same height and place as the other sign-in steps, which have a back button here.
            Row(Modifier.padding(top = Space.sm).height(Size.touch), verticalAlignment = Alignment.CenterVertically) { StepBar(3, 3, Modifier.weight(1f)) }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                Spacer(Modifier.height(Space.xxl))
                Overline("Step 3 of 3")
                Spacer(Modifier.height(Space.sm))
                Text("What should drivers call you?", style = MaterialTheme.typography.headlineLarge, color = colors.onBackground)
                Spacer(Modifier.height(Space.sm))
                Text(
                    "Your driver sees this name during a trip, so they know they've found the right person.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = colors.onSurfaceVariant,
                )
                Spacer(Modifier.height(Space.xl))
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Your name") },
                    singleLine = true,
                    isError = state.error != null,
                    readOnly = state.busy,
                    textStyle = MaterialTheme.typography.titleLarge,
                    shape = Corners.lg,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                    modifier = Modifier.fillMaxWidth(),
                )
                AuthError(state.error)
                if (name.isNotBlank()) {
                    Spacer(Modifier.height(Space.xl))
                    Panel {
                        Overline("Your driver will see")
                        Spacer(Modifier.height(Space.sm))
                        Text(name.trim(), style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
                        Text("Waiting at your pickup", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                    }
                }
            }
            PrimaryButton("Continue", onClick = { onSave(name) }, enabled = ready, busy = state.busy, modifier = Modifier.padding(bottom = Space.lg))
        }
    }
}
