package com.liddr.app.ui.driver

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.liddr.app.ui.booking.RatingForm
import com.liddr.app.ui.kit.CircleButton
import com.liddr.app.ui.kit.EmptyState
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.kit.ScreenTitle
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.launch.AuthProgress
import com.liddr.app.ui.launch.LiddrLogo
import compose.icons.TablerIcons
import compose.icons.tablericons.ChevronLeft
import compose.icons.tablericons.User
import compose.icons.tablericons.WifiOff

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
    BackHandler(enabled = driverBack(state) != DriverBack.LEAVE, onBack = viewModel::back)
    when (state.screen) {
        DriverScreen.LOADING -> Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background), contentAlignment = Alignment.Center) { AuthProgress() }
        DriverScreen.LOAD_FAILED -> Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).windowInsetsPadding(WindowInsets.safeDrawing), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                EmptyState(
                    TablerIcons.WifiOff,
                    "We couldn't load your account",
                    state.error ?: "Check your connection, then try again.",
                    actionLabel = "Try again",
                    onAction = viewModel::retry,
                )
                LinkButton("Account", onAccount)
            }
        }
        DriverScreen.CATEGORY -> CategoryScreen(state, viewModel, onAccount)
        DriverScreen.VERIFICATION -> VerificationScreen(state, viewModel, onAccount)
        DriverScreen.SUBSCRIPTION -> SubscriptionScreen(state, viewModel, onAccount)
        DriverScreen.HOME -> DriverHomeScreen(state, viewModel, onAccount)
        DriverScreen.TRIP -> DriverTripScreen(state, viewModel)
        DriverScreen.RATE -> DriverPage(title = "How was your rider?") {
            Spacer(Modifier.height(Space.xl))
            RatingForm(state.busy, prompt = "Rate your rider", reasons = riderReasons, onSubmit = viewModel::submitRating, onSkip = viewModel::skipRating)
        }
    }
}

/**
 * A driver screen: the logo and Account at the top, a title with one line under
 * it, scrolling content, and the screen's action held at the bottom.
 */
@Composable
internal fun DriverPage(
    title: String,
    onAccount: (() -> Unit)? = null,
    body: String? = null,
    onBack: (() -> Unit)? = null,
    bottom: (@Composable ColumnScope.() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit = {},
) {
    val colors = MaterialTheme.colorScheme
    Column(Modifier.fillMaxSize().background(colors.background).windowInsetsPadding(WindowInsets.safeDrawing).imePadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Gutter, vertical = Space.sm), verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) CircleButton(TablerIcons.ChevronLeft, "Back", onBack) else LiddrLogo()
            Spacer(Modifier.weight(1f))
            if (onAccount != null) CircleButton(TablerIcons.User, "Account", onAccount)
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Gutter)) {
            ScreenTitle(title, modifier = Modifier.padding(top = Space.lg))
            body?.let { Text(it, style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = Space.xs)) }
            content()
            Spacer(Modifier.height(Space.lg))
        }
        if (bottom != null) {
            Column(Modifier.padding(start = Gutter, end = Gutter, bottom = Space.lg), verticalArrangement = Arrangement.spacedBy(Space.sm), content = bottom)
        }
    }
}
