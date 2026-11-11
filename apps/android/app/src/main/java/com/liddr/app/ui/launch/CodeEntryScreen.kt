package com.liddr.app.ui.launch

import androidx.compose.foundation.border
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.theme.LiddrTheme

private const val CODE_LENGTH = 6

@Composable
fun CodeEntryScreen(
    state: AuthUiState,
    onChangeDestination: () -> Unit,
    onEdited: () -> Unit,
    onVerify: (String) -> Unit,
    onResend: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    var code by rememberSaveable { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    // A wrong code is cleared so the next attempt starts from the first box.
    LaunchedEffect(state.error) { if (state.error != null) code = "" }

    OnboardingBackground {
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding()
                .padding(horizontal = 28.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                TextButton(onClick = onChangeDestination) { Text("Back") }
                Spacer(Modifier.height(10.dp))
                LiddrLogo()
                Spacer(Modifier.height(36.dp))
                Text("Enter your code", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold, color = colors.onBackground)
                Spacer(Modifier.height(6.dp))
                Text("Sent to ${state.destination}", style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
                Spacer(Modifier.height(28.dp))
                BasicTextField(
                    value = code,
                    onValueChange = { typed ->
                        val digits = typed.filter(Char::isDigit).take(CODE_LENGTH)
                        code = digits
                        if (digits.isNotEmpty()) onEdited()
                        if (digits.length == CODE_LENGTH && !state.busy) onVerify(digits)
                    },
                    // Read-only, not disabled: a disabled field drops focus and closes the keyboard.
                    readOnly = state.busy,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus).semantics { contentDescription = "Six digit code" },
                    decorationBox = {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            repeat(CODE_LENGTH) { index -> CodeBox(code.getOrNull(index), index == code.length, Modifier.weight(1f)) }
                        }
                    },
                )
                AuthError(state.error)
            }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                when {
                    state.busy -> AuthProgress()
                    state.resendInSeconds > 0 -> Text(
                        "Resend code in ${state.resendInSeconds}s",
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 12.dp),
                    )
                    else -> TextButton(onClick = onResend) { Text("Resend code") }
                }
            }
        }
    }
}

@Composable
private fun CodeBox(digit: Char?, active: Boolean, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    Box(
        modifier.height(56.dp).border(if (active) 2.dp else 1.dp, if (active) colors.primary else colors.outlineVariant, RoundedCornerShape(12.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Text(digit?.toString().orEmpty(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, color = colors.onBackground)
    }
}

@Preview(showBackground = true)
@Composable
private fun CodePreview() {
    LiddrTheme { CodeEntryScreen(AuthUiState(destination = "0712 345 678", resendInSeconds = 24), {}, {}, {}, {}) }
}
