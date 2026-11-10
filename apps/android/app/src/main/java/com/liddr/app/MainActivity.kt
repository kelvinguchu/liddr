package com.liddr.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.liddr.app.data.SessionState
import com.liddr.app.ui.account.AccountViewModel
import com.liddr.app.ui.account.SignedInRoot
import com.liddr.app.ui.booking.BookingRoot
import com.liddr.app.ui.booking.BookingViewModel
import com.liddr.app.ui.booking.IncomingViewModel
import com.liddr.app.service.DriverLocationControl
import com.liddr.app.ui.driver.DriverRoot
import com.liddr.app.ui.driver.DriverViewModel
import com.liddr.app.ui.launch.AuthViewModel
import com.liddr.app.ui.launch.OnboardingNav
import com.liddr.app.ui.theme.LiddrTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as LiddrApp
        setContent { LiddrTheme { AppRoot(app) } }
    }
}

@Composable
private fun AppRoot(app: LiddrApp) {
    LaunchedEffect(Unit) { withContext(Dispatchers.IO) { app.session.restore() } }
    val session by app.session.state.collectAsState()
    when (val current = session) {
        // Reading saved tokens takes milliseconds, so this is a blank frame, not a spinner.
        SessionState.Loading -> Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background))
        is SessionState.SignedOut -> OnboardingNav(
            viewModel(key = "auth-${current.generation}", factory = viewModelFactory { initializer { AuthViewModel(app.api) } }),
        )
        is SessionState.SignedIn -> {
            LiveWhileVisible(app)
            SignedInRoot(
            viewModel(key = "account-${current.generation}", factory = viewModelFactory { initializer { AccountViewModel(app.api, app.session) } }),
            riderHome = { onAccount ->
                BookingRoot(
                    viewModel(key = "booking-${current.generation}", factory = viewModelFactory { initializer { BookingViewModel(app.api, app.send, app.places, app.locator, app.realtime) } }),
                    viewModel(key = "incoming-${current.generation}", factory = viewModelFactory { initializer { IncomingViewModel(app.send, app.realtime) } }),
                    onAccount,
                )
            },
            driverHome = { onAccount ->
                DriverRoot(
                    viewModel(key = "driver-${current.generation}", factory = viewModelFactory { initializer { DriverViewModel(app.drivers, app.api, app.send, DriverLocationControl(app), app.realtime) } }),
                    onAccount,
                )
            },
        )
        }
    }
}

/** Keeps the live socket open while a signed-in person has the app on screen. */
@Composable
private fun LiveWhileVisible(app: LiddrApp) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val scope = rememberCoroutineScope()
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) app.realtime.start(scope)
            if (event == Lifecycle.Event.ON_STOP) app.realtime.stop()
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            app.realtime.stop()
        }
    }
}
