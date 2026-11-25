package com.liddr.app.ui.booking

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.ScreenTitle
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Space
import compose.icons.TablerIcons
import compose.icons.tablericons.History
import compose.icons.tablericons.Home
import compose.icons.tablericons.User

internal enum class RiderTab { HOME, TRIPS }

/** The tab Back goes to, or null when Back leaves the app. */
internal fun backFrom(tab: RiderTab): RiderTab? = if (tab == RiderTab.HOME) null else RiderTab.HOME

/**
 * Home and Trips under a floating dock of three: Home, Trips and Account. The
 * tab you are on is filled in. Booking starts from the ticket on Home, so the
 * dock carries no second Where to?.
 */
@Composable
internal fun RiderTabs(state: BookingUiState, viewModel: BookingViewModel, home: HomeViewModel, incoming: IncomingViewModel, onAccount: () -> Unit) {
    var tab by rememberSaveable { mutableStateOf(RiderTab.HOME) }
    BackHandler(enabled = backFrom(tab) != null) { backFrom(tab)?.let { tab = it } }
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        when (tab) {
            RiderTab.HOME -> HomeScreen(state, viewModel, home, incoming, onSeeAllTrips = { tab = RiderTab.TRIPS })
            RiderTab.TRIPS -> TripsScreen(viewModel, home)
        }
        Dock(
            Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(horizontal = Gutter, vertical = Space.md),
        ) {
            DockTab(TablerIcons.Home, "Home", tab == RiderTab.HOME) { tab = RiderTab.HOME }
            DockTab(TablerIcons.History, "Trips", tab == RiderTab.TRIPS) { tab = RiderTab.TRIPS }
            DockTab(TablerIcons.User, "Account", selected = false, onClick = onAccount)
        }
    }
}

@Composable
private fun Dock(modifier: Modifier, tabs: @Composable RowScope.() -> Unit) {
    Surface(shape = CircleShape, color = MaterialTheme.colorScheme.surfaceContainerHigh, shadowElevation = DockShadow, modifier = modifier.fillMaxWidth().height(Size.dock)) {
        Row(Modifier.padding(Space.xs).selectableGroup(), horizontalArrangement = Arrangement.spacedBy(Space.xs), content = tabs)
    }
}

@Composable
private fun RowScope.DockTab(icon: ImageVector, label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val tint = if (selected) colors.onPrimaryContainer else colors.onSurfaceVariant
    Row(
        Modifier.weight(1f).fillMaxHeight().clip(CircleShape)
            .background(if (selected) colors.primaryContainer else Color.Transparent)
            .selectable(selected = selected, role = Role.Tab, onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, Modifier.size(Size.smallIcon), tint = tint)
        Spacer(Modifier.width(Space.sm))
        Text(label, style = MaterialTheme.typography.labelLarge, color = tint)
    }
}

/** Every recent trip, newest first, each ready to book again. */
@Composable
private fun TripsScreen(viewModel: BookingViewModel, home: HomeViewModel) {
    val state by home.ui.collectAsState()
    LaunchedEffect(Unit) { home.refresh() }
    Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = Gutter)) {
        ScreenTitle("Your trips", modifier = Modifier.padding(top = Space.xl, bottom = Space.lg))
        RecentTrips(state, onRetry = home::loadTrips) { item -> home.again(item) { place, category -> viewModel.rebook(place, category) } }
        DockSpacer()
    }
}

/** Room under scrolling content so its last item clears the dock and the system bar. */
@Composable
internal fun DockSpacer() {
    Spacer(Modifier.navigationBarsPadding().height(Size.dock + Space.md * 2 + Space.sm))
}

private val DockShadow = 8.dp
