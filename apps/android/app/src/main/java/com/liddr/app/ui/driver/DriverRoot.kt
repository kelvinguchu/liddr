package com.liddr.app.ui.driver

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.liddr.app.ui.booking.BodyText
import com.liddr.app.ui.booking.Heading
import com.liddr.app.ui.booking.Page
import com.liddr.app.ui.booking.RatingForm
import com.liddr.app.ui.launch.AuthProgress

private val riderReasons = listOf(
    "late" to "Kept me waiting",
    "rude" to "Rude",
    "wrong_pickup_pin" to "Wrong pickup point",
    "unsafe_behaviour" to "Unsafe behaviour",
    "traffic" to "Traffic",
    "app_issue" to "App problem",
)

/** Shows the step this driver has reached: each must be done before the next opens. */
@Composable
fun DriverRoot(viewModel: DriverViewModel, onAccount: () -> Unit) {
    val state by viewModel.ui.collectAsState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) viewModel.setVisible(true)
            if (event == Lifecycle.Event.ON_STOP) viewModel.setVisible(false)
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    when (state.screen) {
        DriverScreen.LOADING -> Page { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { AuthProgress() } }
        DriverScreen.LOAD_FAILED -> Page {
            Spacer(Modifier.height(40.dp))
            Heading("We couldn't load your account")
            BodyText(state.error.orEmpty())
            TextButton(onClick = viewModel::retry) { Text("Try again") }
            TextButton(onClick = onAccount) { Text("Account") }
        }
        DriverScreen.CATEGORY -> CategoryScreen(state, viewModel, onAccount)
        DriverScreen.VERIFICATION -> VerificationScreen(state, viewModel, onAccount)
        DriverScreen.SUBSCRIPTION -> SubscriptionScreen(state, viewModel, onAccount)
        DriverScreen.HOME -> DriverHomeScreen(state, viewModel, onAccount)
        DriverScreen.TRIP -> DriverTripScreen(state, viewModel)
        DriverScreen.RATE -> Page {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                Spacer(Modifier.height(40.dp))
                Heading("How was your rider?")
                Spacer(Modifier.height(16.dp))
                RatingForm(state.busy, state.error, "Rate your rider", riderReasons, viewModel::submitRating, viewModel::skipRating)
            }
        }
    }
}
