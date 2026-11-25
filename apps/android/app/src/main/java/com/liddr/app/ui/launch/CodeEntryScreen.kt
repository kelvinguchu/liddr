package com.liddr.app.ui.launch

import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Corners
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.kit.CircleButton
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.kit.Overline
import com.liddr.app.ui.kit.StepBar
import com.liddr.app.ui.theme.LiddrTheme
import compose.icons.TablerIcons
import compose.icons.tablericons.ChevronLeft
import compose.icons.tablericons.Message

private const val CODE_LENGTH = 6

/** Step 2 of sign-in. The code checks itself at six digits, typed or read from the SMS. */
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
    // A code read from the SMS fills the boxes; the view model is already checking it.
    LaunchedEffect(state.autoCode) { state.autoCode?.let { code = it } }
    val byPhone = state.destination.none { it == '@' }

    OnboardingBackground {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding().padding(horizontal = Gutter)) {
            Row(Modifier.padding(top = Space.sm), verticalAlignment = Alignment.CenterVertically) {
                CircleButton(TablerIcons.ChevronLeft, "Back", onChangeDestination)
                Spacer(Modifier.width(Space.lg))
                StepBar(2, 3, Modifier.weight(1f))
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                Spacer(Modifier.height(Space.xxl))
                Overline("Step 2 of 3")
                Spacer(Modifier.height(Space.sm))
                Text("Enter the code", style = MaterialTheme.typography.headlineLarge, color = colors.onBackground)
                Spacer(Modifier.height(Space.sm))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Sent to ", style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
                    Text(displayDestination(state.destination), style = MaterialTheme.typography.bodyLarge, color = colors.onBackground)
                }
                LinkButton("Change", onChangeDestination)
                Spacer(Modifier.height(Space.lg))
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
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Space.sm)) {
                            repeat(CODE_LENGTH) { index -> CodeBox(code.getOrNull(index), index == code.length, Modifier.weight(1f)) }
                        }
                    },
                )
                AuthError(state.error)
                if (byPhone) {
                    Spacer(Modifier.height(Space.xl))
                    Row(
                        Modifier.fillMaxWidth().clip(Corners.md).background(colors.tertiaryContainer).padding(horizontal = Space.lg, vertical = Space.md),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(TablerIcons.Message, null, Modifier.size(Size.icon), tint = colors.onSurface)
                        Spacer(Modifier.width(Space.md))
                        Text("We'll fill it in for you when the SMS arrives.", style = MaterialTheme.typography.bodyMedium, color = colors.onSurface)
                    }
                }
            }
            Box(Modifier.fillMaxWidth().padding(bottom = Space.lg), contentAlignment = Alignment.Center) {
                when {
                    state.busy -> AuthProgress()
                    state.resendInSeconds > 0 -> Text(
                        "Resend code in 0:%02d".format(state.resendInSeconds),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = Space.md),
                    )
                    else -> LinkButton("Resend code", onResend)
                }
            }
        }
    }
}

/** "0712345678" becomes "+254 712 345 678"; an email is shown as typed. */
internal fun displayDestination(destination: String): String {
    if ('@' in destination) return destination
    val national = nationalDigits(destination)
    if (national.length != 9) return destination
    return "+254 ${national.substring(0, 3)} ${national.substring(3, 6)} ${national.substring(6)}"
}

@Composable
private fun CodeBox(digit: Char?, active: Boolean, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val shape = Corners.md
    Box(
        modifier.height(Size.tallField).clip(shape)
            .background(if (digit != null) colors.surfaceContainerLow else colors.surface)
            .border(if (active) FocusBorder else Hairline, if (active) colors.secondary else colors.outlineVariant, shape),
        contentAlignment = Alignment.Center,
    ) {
        Text(digit?.toString().orEmpty(), style = MaterialTheme.typography.headlineMedium, color = colors.onBackground)
    }
}

@Preview(showBackground = true)
@Composable
private fun CodePreview() {
    LiddrTheme(darkTheme = false) { CodeEntryScreen(AuthUiState(destination = "0712345678", resendInSeconds = 24), {}, {}, {}, {}) }
}

private val FocusBorder = 2.dp
private val Hairline = 1.dp
