package com.liddr.app.ui.launch

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue

@Composable
fun OnboardingNav(viewModel: AuthViewModel) {
        val state by viewModel.ui.collectAsState()
        var role by rememberSaveable { mutableStateOf<AccountRoleUi?>(null) }
        var methodKey by rememberSaveable { mutableStateOf<String?>(null) }

        // Sign-in starts with the phone number; riders may switch to email.
        val step =
                when {
                        role == null -> 0
                        state.challengeId == null -> 1
                        else -> 2
                }
        val method = allOnboardingMethods.firstOrNull { it.method == methodKey } ?: allOnboardingMethods.first()
        val email = allOnboardingMethods.firstOrNull { it.method == "email_otp" }
        val back: () -> Unit = {
                when (step) {
                        2 -> viewModel.editDestination()
                        else -> {
                                viewModel.clearError()
                                methodKey = null
                                role = null
                        }
                }
        }
        BackHandler(enabled = step > 0, onBack = back)

        AnimatedContent(
                targetState = step,
                transitionSpec = {
                        val forward = targetState > initialState
                        val enterDuration = if (forward) 280 else 220
                        val exitDuration = if (forward) 240 else 190
                        val fadeInDuration = if (forward) 260 else 200
                        val fadeOutDuration = if (forward) 200 else 160
                        val distanceDivisor = if (forward) 4 else 5

                        val enter =
                                slideInHorizontally(
                                        animationSpec =
                                                tween(
                                                        durationMillis = enterDuration,
                                                        easing = FastOutSlowInEasing
                                                )
                                ) { fullWidth ->
                                        if (forward) fullWidth / distanceDivisor
                                        else -fullWidth / distanceDivisor
                                } +
                                        fadeIn(
                                                animationSpec =
                                                        tween(
                                                                durationMillis = fadeInDuration,
                                                                easing = FastOutSlowInEasing
                                                        )
                                        )

                        val exit =
                                slideOutHorizontally(
                                        animationSpec =
                                                tween(
                                                        durationMillis = exitDuration,
                                                        easing = FastOutSlowInEasing
                                                )
                                ) { fullWidth ->
                                        if (forward) -fullWidth / distanceDivisor
                                        else fullWidth / distanceDivisor
                                } +
                                        fadeOut(
                                                animationSpec =
                                                        tween(
                                                                durationMillis = fadeOutDuration,
                                                                easing = FastOutSlowInEasing
                                                        )
                                        )

                        enter.togetherWith(exit).using(SizeTransform(clip = false))
                },
                label = "onboarding"
        ) { s ->
                when (s) {
                        0 -> FirstScreen(onRoleSelected = { role = it })
                        1 -> {
                                val chosen = role ?: AccountRoleUi.RIDER
                                val canSwitch = email != null && chosen in email.allowedRoles
                                AuthMethodEntryScreen(
                                        role = chosen,
                                        method = method,
                                        state = state,
                                        onBack = back,
                                        onValueEdited = viewModel::clearError,
                                        onContinue = { entered -> viewModel.sendCode(chosen, method, entered) },
                                        onSwitchMethod =
                                                if (canSwitch) {
                                                        {
                                                                viewModel.clearError()
                                                                methodKey = if (method.method == "phone_otp") "email_otp" else "phone_otp"
                                                        }
                                                } else null,
                                )
                        }
                        else ->
                                CodeEntryScreen(
                                        state = state,
                                        onChangeDestination = back,
                                        onEdited = viewModel::clearError,
                                        onVerify = viewModel::verify,
                                        onResend = viewModel::resend
                                )
                }
        }
}
