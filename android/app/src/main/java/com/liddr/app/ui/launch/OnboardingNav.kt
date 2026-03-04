package com.liddr.app.ui.launch

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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue

@Composable
fun OnboardingNav() {
    var role by rememberSaveable { mutableStateOf<AccountRoleUi?>(null) }
    var mode by rememberSaveable { mutableStateOf(AuthModeUi.SIGN_UP) }
    var methodKey by rememberSaveable { mutableStateOf<String?>(null) }

    val step =
            when {
                role == null -> 0
                methodKey == null -> 1
                else -> 2
            }
    val method = allOnboardingMethods.firstOrNull { it.method == methodKey }

    AnimatedContent(
            targetState = step,
            transitionSpec = {
                val fwd = targetState > initialState
                val enter =
                        slideInHorizontally(tween(300, easing = FastOutSlowInEasing)) {
                            if (fwd) it / 4 else -it / 4
                        } + fadeIn(tween(300))
                val exit =
                        slideOutHorizontally(tween(300, easing = FastOutSlowInEasing)) {
                            if (fwd) -it / 4 else it / 4
                        } + fadeOut(tween(300))
                enter.togetherWith(exit).using(SizeTransform(clip = false))
            },
            label = "onboarding"
    ) { s ->
        when (s) {
            0 ->
                    FirstScreen(
                            onRoleSelected = { r ->
                                role = r
                                methodKey = null
                                mode = AuthModeUi.SIGN_UP
                            }
                    )
            1 ->
                    AuthGatewayScreen(
                            role = role ?: AccountRoleUi.RIDER,
                            mode = mode,
                            onBack = {
                                role = null
                                methodKey = null
                            },
                            onModeChange = { mode = it },
                            onMethodSelected = { methodKey = it.method }
                    )
            else ->
                    AuthMethodEntryScreen(
                            role = role ?: AccountRoleUi.RIDER,
                            mode = mode,
                            method = method ?: allOnboardingMethods.first(),
                            onBack = { methodKey = null },
                            onContinue = {}
                    )
        }
    }
}
