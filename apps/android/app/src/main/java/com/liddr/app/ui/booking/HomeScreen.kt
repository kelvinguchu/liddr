package com.liddr.app.ui.booking

import com.liddr.app.ui.kit.bleedToEdges
import com.liddr.app.ui.kit.RouteNode
import com.liddr.app.ui.kit.SmallButton
import com.liddr.app.ui.kit.Thumbnail
import com.liddr.app.ui.kit.EmptyState
import androidx.compose.ui.semantics.clearAndSetSemantics
import com.liddr.app.ui.kit.SkeletonRow
import compose.icons.tablericons.History
import compose.icons.tablericons.WifiOff
import com.liddr.app.ui.kit.ListRow
import com.liddr.app.ui.kit.SectionHeader
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Corners
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.liddr.app.data.HistoryItem
import com.liddr.app.data.RideStatus
import com.liddr.app.data.VehicleCategory
import com.liddr.app.ui.kit.CircleButton
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.kit.Overline
import com.liddr.app.ui.kit.Panel
import com.liddr.app.ui.kit.Perforation
import com.liddr.app.ui.kit.TicketShape
import com.liddr.app.ui.launch.AuthProgress
import com.liddr.app.ui.launch.LiddrLogo
import compose.icons.TablerIcons
import compose.icons.tablericons.ArrowRight
import compose.icons.tablericons.User

/**
 * Home is the trip ticket: where you are, then Where to? below the perforation.
 * Under it, how you want to go and your recent trips. No map until there is a route.
 */
@Composable
internal fun HomeScreen(state: BookingUiState, viewModel: BookingViewModel, home: HomeViewModel, incoming: IncomingViewModel, onSeeAllTrips: () -> Unit) {
    val context = LocalContext.current
    val colors = MaterialTheme.colorScheme
    val homeState by home.ui.collectAsState()
    fun granted() = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
    var refused by rememberSaveable { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        if (results.values.any { it }) viewModel.useCurrentLocation() else refused = true
    }
    LaunchedEffect(Unit) {
        home.refresh()
        if (state.pickup == null && granted()) viewModel.useCurrentLocation()
    }

    Column(Modifier.fillMaxSize().background(colors.background).statusBarsPadding()) {
        LiddrLogo(Modifier.padding(Gutter))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Gutter)) {
            IncomingPackageCard(incoming)
            Text(
                listOfNotNull(greeting(), homeState.firstName).joinToString(", "),
                style = MaterialTheme.typography.titleMedium,
                color = colors.onSurfaceVariant,
                modifier = Modifier.padding(top = Space.sm),
            )
            Text("Where are we going?", style = MaterialTheme.typography.headlineMedium, color = colors.onBackground)
            Spacer(Modifier.height(Space.lg))
            TripTicket(
                pickup = state.pickup?.title ?: if (state.locating) "Finding your location…" else "Set your pickup",
                pickupSet = state.pickup != null,
                onPickup = { viewModel.openSearch(SearchTarget.PICKUP) },
                onWhereTo = { viewModel.openSearch(SearchTarget.DROPOFF) },
            )
            if (state.pickup == null && !state.locating) {
                if (refused) {
                    Text("Location is off for Liddr. Turn it on in Settings, or set your pickup above.", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = Space.sm))
                    LinkButton("Open Settings", { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))) })
                } else {
                    LinkButton("Use my location", {
                        if (granted()) viewModel.useCurrentLocation()
                        else ask.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                    })
                }
            }
            if (!homeState.categoriesLoaded) {
                SectionHeader("How do you want to go?")
                ChoicePlaceholders()
            } else if (homeState.categories.isNotEmpty()) {
                SectionHeader("How do you want to go?")
                VehicleChoices(homeState.categories, state.preferred, viewModel::prefer)
            }
            SectionHeader("Recent trips", actionLabel = "See all".takeIf { (homeState.recent?.size ?: 0) > RECENT_ON_HOME }, onAction = onSeeAllTrips)
            RecentTrips(homeState, limit = RECENT_ON_HOME, onRetry = home::loadTrips) { item -> home.again(item) { place, category -> viewModel.rebook(place, category) } }
            DockSpacer()
        }
    }
}

/** From your pickup, a perforation, then Where to? with the one action on the screen. */
@Composable
private fun TripTicket(pickup: String, pickupSet: Boolean, onPickup: () -> Unit, onWhereTo: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(shape = TicketShape(cutAt = Size.tallRow), color = colors.surfaceContainerLow, modifier = Modifier.fillMaxWidth()) {
        Box {
            // The route between the two ends of the trip.
            Box(Modifier.offset(x = RailX, y = RailTop).width(RailWidth).height(RailLength).background(colors.outline))
            Column {
                Row(Modifier.fillMaxWidth().height(Size.tallRow).clickable(onClick = onPickup).padding(start = Gutter, end = Space.sm), verticalAlignment = Alignment.CenterVertically) {
                    RouteNode(pickup = true)
                    Spacer(Modifier.width(Space.md))
                    Column(Modifier.weight(1f)) {
                        Overline("From")
                        Text(pickup, style = MaterialTheme.typography.titleMedium, color = if (pickupSet) colors.onSurface else colors.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    LinkButton("Change", onPickup)
                }
                Perforation(Modifier.padding(horizontal = Space.lg))
                Row(Modifier.fillMaxWidth().height(WhereToHeight).clickable(onClick = onWhereTo).padding(horizontal = Gutter), verticalAlignment = Alignment.CenterVertically) {
                    RouteNode(pickup = false)
                    Spacer(Modifier.width(Space.md))
                    Column(Modifier.weight(1f)) {
                        Text("Where to?", style = MaterialTheme.typography.headlineSmall, color = colors.onSurface)
                        Text("A street, estate or landmark", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                    }
                    Box(Modifier.size(Size.touch).clip(CircleShape).background(colors.primary), contentAlignment = Alignment.Center) {
                        Icon(TablerIcons.ArrowRight, contentDescription = null, tint = colors.onPrimary, modifier = Modifier.size(Size.icon))
                    }
                }
            }
        }
    }
}

/** Compact, scrollable choices; the picked one is chosen first when fares arrive. */
@Composable
private fun VehicleChoices(categories: List<VehicleCategory>, preferred: String?, onPick: (String) -> Unit) {
    val colors = MaterialTheme.colorScheme
    // Runs to the screen edges so the next choice peeks in, rather than being cut at the gutter.
    Row(Modifier.bleedToEdges(Gutter).horizontalScroll(rememberScrollState()).padding(horizontal = Gutter), horizontalArrangement = Arrangement.spacedBy(Space.sm)) {
        categories.forEach { category ->
            val picked = category.slug == preferred
            Surface(
                onClick = { onPick(category.slug) },
                shape = Corners.lg,
                // Chosen is marked with the teal stripe, as on the vehicles themselves.
                color = colors.surfaceContainerLow,
                border = BorderStroke(if (picked) FocusBorder else Hairline, if (picked) colors.secondary else colors.surfaceContainerLow),
                modifier = Modifier.width(ChoiceWidth).height(ChoiceHeight),
            ) {
                Column(Modifier.padding(Space.sm), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    VehicleArt(category.slug, Size.touch)
                    Spacer(Modifier.height(Space.xs))
                    Text(shortLabel(category), style = MaterialTheme.typography.labelLarge, color = colors.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/** Holds the vehicle row's place while the types load, so nothing below jumps. */
@Composable
private fun ChoicePlaceholders() {
    Row(Modifier.bleedToEdges(Gutter).padding(horizontal = Gutter).clearAndSetSemantics {}, horizontalArrangement = Arrangement.spacedBy(Space.sm)) {
        repeat(SKELETON_TRIPS) { Box(Modifier.width(ChoiceWidth).height(ChoiceHeight).clip(Corners.lg).background(MaterialTheme.colorScheme.surfaceContainerLow)) }
    }
}

@Composable
internal fun RecentTrips(state: HomeUiState, limit: Int = Int.MAX_VALUE, onRetry: () -> Unit, onAgain: (HistoryItem) -> Unit) {
    val recent = state.recent
    when {
        recent == null && state.tripsFailed -> EmptyState(TablerIcons.WifiOff, "We couldn't load your trips", "Check your connection, then try again.", actionLabel = "Try again", onAction = onRetry)
        recent == null -> repeat(minOf(limit, SKELETON_TRIPS)) { SkeletonRow(Modifier.bleedToEdges(Gutter)) }
        recent.isEmpty() -> EmptyState(TablerIcons.History, "No trips yet", "Your trips will show up here, ready to book again in one tap.")
        else -> recent.take(limit).forEach { item -> TripRow(item, state.names[item.id], reopening = state.reopening == item.id) { onAgain(item) } }
    }
}

@Composable
private fun TripRow(item: HistoryItem, destination: String?, reopening: Boolean, onAgain: () -> Unit) {
    ListRow(
        title = destination ?: "${vehicleName(item.category)} trip",
        supporting = listOf(tripDate(item.requestedAt), money(item.fareKes), tripOutcome(item.status)).filter(String::isNotEmpty).joinToString(" · "),
        modifier = Modifier.bleedToEdges(Gutter),
        leading = { Thumbnail { VehicleArt(item.category, Size.art) } },
        trailing = {
            when {
                reopening -> AuthProgress()
                !RideStatus.isActive(item.status) -> SmallButton("Again", onAgain)
            }
        },
    )
}

private fun tripOutcome(status: String) = when (status) {
    RideStatus.COMPLETED -> "Completed"
    RideStatus.CANCELLED -> "Cancelled"
    RideStatus.NO_DRIVERS -> "No driver found"
    else -> "In progress"
}

/** A label short enough for a choice chip. */
private fun shortLabel(category: VehicleCategory) = if (category.slug == "electric_motorbike") "E-motorbike" else category.label

private const val RECENT_ON_HOME = 3
private const val SKELETON_TRIPS = 3

// The ticket's route line runs from the pickup node to the destination node.
// Declared in order: each value only uses ones above it.
private val RailWidth = 2.dp
private val WhereToHeight = 88.dp
private val RailX = Gutter + Size.icon / 2 - RailWidth / 2
private val RailTop = Size.tallRow / 2 + Size.icon / 4
private val RailLength = WhereToHeight / 2 + Size.tallRow / 2 - Size.icon / 2
private val ChoiceWidth = 104.dp
private val ChoiceHeight = 96.dp
private val Hairline = 1.dp
private val FocusBorder = 2.dp
