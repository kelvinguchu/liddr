package com.liddr.app.ui.launch

import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Corners
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.kit.CircleButton
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.kit.Overline
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.StepBar
import com.liddr.app.ui.theme.LiddrTheme
import compose.icons.TablerIcons
import compose.icons.tablericons.ChevronLeft

/** Step 1 of sign-in: the phone number (or, for riders, an email) to send a code to. */
@Composable
fun AuthMethodEntryScreen(
    role: AccountRoleUi,
    method: AuthMethodUi,
    state: AuthUiState,
    onBack: () -> Unit,
    onValueEdited: () -> Unit,
    onContinue: (String) -> Unit,
    onSwitchMethod: (() -> Unit)? = null,
) {
    val colors = MaterialTheme.colorScheme
    val phone = method.method == "phone_otp"
    var value by rememberSaveable(method.method) { mutableStateOf(if (phone) nationalDigits(state.destination) else state.destination) }
    val entered = if (phone) "0$value" else value
    val focus = remember { FocusRequester() }
    LaunchedEffect(method.method) { focus.requestFocus() }
    val ready = method.isValid(entered) && !state.busy && state.resendInSeconds == 0
    val send = { if (ready) onContinue(entered) }

    OnboardingBackground {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding().padding(horizontal = Gutter)) {
            Row(Modifier.padding(top = Space.sm), verticalAlignment = Alignment.CenterVertically) {
                CircleButton(TablerIcons.ChevronLeft, "Back", onBack)
                Spacer(Modifier.width(Space.lg))
                StepBar(1, 3, Modifier.weight(1f))
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                Spacer(Modifier.height(Space.xxl))
                Overline("${role.title} · step 1 of 3")
                Spacer(Modifier.height(Space.sm))
                Text(if (phone) "What's your number?" else "What's your email?", style = MaterialTheme.typography.headlineLarge, color = colors.onBackground)
                Spacer(Modifier.height(Space.sm))
                Text(
                    if (phone) "We'll text you a 6-digit code. No password to remember." else method.prompt,
                    style = MaterialTheme.typography.bodyLarge,
                    color = colors.onSurfaceVariant,
                )
                Spacer(Modifier.height(Space.xl))
                val outline = when {
                    state.error != null -> colors.error
                    else -> colors.secondary
                }
                Surface(
                    shape = Corners.lg,
                    color = colors.surface,
                    border = BorderStroke(FocusBorder, outline),
                    modifier = Modifier.fillMaxWidth().height(Size.tallField),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (phone) {
                            Box(Modifier.fillMaxHeight().background(colors.surfaceContainerLow).padding(horizontal = Space.lg), contentAlignment = Alignment.Center) {
                                Text("+254", style = MaterialTheme.typography.titleLarge, color = colors.onSurface)
                            }
                        }
                        BasicTextField(
                            value = value,
                            onValueChange = {
                                value = if (phone) nationalDigits(it) else it
                                onValueEdited()
                            },
                            singleLine = true,
                            readOnly = state.busy,
                            textStyle = MaterialTheme.typography.titleLarge.copy(color = colors.onSurface),
                            cursorBrush = SolidColor(colors.secondary),
                            keyboardOptions = KeyboardOptions(keyboardType = method.keyboard, imeAction = ImeAction.Go),
                            keyboardActions = KeyboardActions(onGo = { send() }),
                            decorationBox = { field ->
                                Box(contentAlignment = Alignment.CenterStart) {
                                    if (value.isEmpty()) {
                                        Text(if (phone) "712 345 678" else method.hint, style = MaterialTheme.typography.titleLarge, color = colors.onSurfaceVariant.copy(alpha = 0.6f))
                                    }
                                    field()
                                }
                            },
                            modifier = Modifier.weight(1f).padding(horizontal = Space.lg).focusRequester(focus)
                                .semantics { contentDescription = method.label },
                        )
                    }
                }
                Spacer(Modifier.height(Space.sm))
                if (state.error != null) {
                    AuthError(state.error)
                    if (state.resendInSeconds > 0) {
                        Text("You can try again in ${state.resendInSeconds}s.", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                    }
                } else if (phone) {
                    Text("Safaricom, Airtel or Telkom. Starts with 7 or 1.", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                }
            }
            Column(Modifier.padding(bottom = Space.lg), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                PrimaryButton("Send code", onClick = send, enabled = ready, busy = state.busy)
                if (onSwitchMethod != null) {
                    LinkButton(if (phone) "Use email instead" else "Use my phone number instead", onSwitchMethod, Modifier.align(Alignment.CenterHorizontally))
                }
            }
        }
    }
}

/** The nine national digits of a Kenyan mobile number, however it was typed. */
internal fun nationalDigits(typed: String): String {
    val digits = typed.filter(Char::isDigit)
    return when {
        digits.startsWith("254") -> digits.drop(3)
        digits.startsWith("0") -> digits.drop(1)
        else -> digits
    }.take(9)
}

@Preview(showBackground = true)
@Composable
private fun EntryPreview() {
    LiddrTheme(darkTheme = false) {
        AuthMethodEntryScreen(AccountRoleUi.RIDER, allOnboardingMethods.first(), AuthUiState(), {}, {}, {}, {})
    }
}

private val FocusBorder = 2.dp
