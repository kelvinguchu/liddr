package com.liddr.app.ui.booking

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.ScreenTitle
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.launch.AuthProgress
import com.liddr.app.ui.launch.OnboardingBackground

@Composable
fun BookingRoot(viewModel: BookingViewModel, home: HomeViewModel, incoming: IncomingViewModel, onAccount: () -> Unit) {
    val state by viewModel.ui.collectAsState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) {
                viewModel.setVisible(true)
                incoming.check()
            }
            if (event == Lifecycle.Event.ON_STOP) viewModel.setVisible(false)
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    BackHandler(enabled = state.stage in setOf(Stage.SEARCH, Stage.OPTIONS, Stage.SEND_DETAILS), onBack = viewModel::back)
    when (state.stage) {
        Stage.RESUMING -> Page { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { AuthProgress() } }
        Stage.HOME -> RiderTabs(state, viewModel, home, incoming, onAccount)
        Stage.SEARCH -> SearchScreen(state, viewModel, recentPlaces(home.ui.collectAsState().value))
        Stage.OPTIONS -> OptionsScreen(state, viewModel)
        Stage.SEND_DETAILS -> SendDetailsScreen(state, viewModel)
        Stage.TRIP -> TripScreen(state, viewModel)
        Stage.RATE -> Page {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                ScreenTitle("How was your last trip?", modifier = Modifier.padding(top = Space.xxl, bottom = Space.xl))
                RatingForm(state.busy, onSubmit = viewModel::submitRating, onSkip = viewModel::skipRating)
            }
        }
    }
}

@Composable
internal fun Page(content: @Composable ColumnScope.() -> Unit) {
    OnboardingBackground {
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding().padding(horizontal = Gutter, vertical = Space.md),
            content = content,
        )
    }
}

@Composable
internal fun Heading(text: String) {
    Text(text, style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.onBackground)
}

@Composable
internal fun BodyText(text: String) {
    Text(text, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

