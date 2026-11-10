package com.liddr.app.ui.launch

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.theme.LiddrTheme

@Composable
fun AuthMethodEntryScreen(
    role: AccountRoleUi,
    method: AuthMethodUi,
    state: AuthUiState,
    onBack: () -> Unit,
    onValueEdited: () -> Unit,
    onContinue: (String) -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    var value by rememberSaveable(method.method) { mutableStateOf(state.destination) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(method.method) { focus.requestFocus() }
    val ready = method.isValid(value) && !state.busy && state.resendInSeconds == 0

    OnboardingBackground {
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding()
                .padding(horizontal = 28.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                TextButton(onClick = onBack) { Text("Back") }
                Spacer(Modifier.height(10.dp))
                LiddrLogo()
                Spacer(Modifier.height(36.dp))
                Text(
                    method.label,
                    style = MaterialTheme.typography.headlineLarge,
                    fontWeight = FontWeight.Bold,
                    color = colors.onBackground,
                )
                Spacer(Modifier.height(6.dp))
                Text("${method.prompt} Continuing as ${role.title.lowercase()}.", style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
                Spacer(Modifier.height(28.dp))
                OutlinedTextField(
                    value = value,
                    onValueChange = {
                        value = it
                        onValueEdited()
                    },
                    placeholder = { Text(method.hint) },
                    singleLine = true,
                    isError = state.error != null,
                    readOnly = state.busy,
                    keyboardOptions = KeyboardOptions(keyboardType = method.keyboard, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { if (ready) onContinue(value) }),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus),
                )
                AuthError(state.error)
                if (state.resendInSeconds > 0 && state.error != null) {
                    Text("You can try again in ${state.resendInSeconds}s.", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                }
            }
            AuthPrimaryButton(label = "Send code", enabled = ready, busy = state.busy, onClick = { onContinue(value) })
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun EntryPreview() {
    LiddrTheme {
        AuthMethodEntryScreen(AccountRoleUi.RIDER, allOnboardingMethods.first(), AuthUiState(), {}, {}, {})
    }
}
