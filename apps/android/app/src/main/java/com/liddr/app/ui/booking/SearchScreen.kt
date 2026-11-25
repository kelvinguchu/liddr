package com.liddr.app.ui.booking

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.liddr.app.data.Place
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.kit.EmptyState
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.ListRow
import com.liddr.app.ui.kit.ScreenHeader
import com.liddr.app.ui.kit.SectionHeader
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.SkeletonRow
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.kit.RouteNode
import compose.icons.TablerIcons
import compose.icons.tablericons.CurrentLocation
import compose.icons.tablericons.History
import compose.icons.tablericons.MapPin
import compose.icons.tablericons.Search
import compose.icons.tablericons.WifiOff
import compose.icons.tablericons.X

/**
 * Pickup and destination at the top. Before typing, the rider's own places;
 * while typing, the matches; and when search fails, why, with a way to retry.
 */
@Composable
internal fun SearchScreen(state: BookingUiState, viewModel: BookingViewModel, recent: List<Place>) {
    val colors = MaterialTheme.colorScheme
    val focus = remember { FocusRequester() }
    LaunchedEffect(state.target) { focus.requestFocus() }
    val pickupActive = state.target == SearchTarget.PICKUP
    val results = state.results
    Column(Modifier.fillMaxSize().background(colors.background).windowInsetsPadding(WindowInsets.safeDrawing).imePadding()) {
        ScreenHeader("Plan your trip", onBack = viewModel::back)
        Column(Modifier.padding(horizontal = Gutter, vertical = Space.sm), verticalArrangement = Arrangement.spacedBy(Space.sm)) {
            TripField("From", true, pickupActive, if (pickupActive) state.query else state.pickup?.title.orEmpty(), viewModel::onQueryChanged, focus) {
                viewModel.openSearch(SearchTarget.PICKUP)
            }
            TripField("To", false, !pickupActive, if (pickupActive) state.dropoff?.title.orEmpty() else state.query, viewModel::onQueryChanged, focus) {
                viewModel.openSearch(SearchTarget.DROPOFF)
            }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
            if (pickupActive && state.searchError == null) {
                item {
                    ListRow("Use my current location", onClick = {
                        viewModel.useCurrentLocation()
                        viewModel.back()
                    }, leading = { PlaceIcon(TablerIcons.CurrentLocation, highlight = true) })
                }
            }
            when {
                state.searchError != null -> item {
                    EmptyState(TablerIcons.WifiOff, "Search isn't working right now", "Check your connection, then try again.", actionLabel = "Try again", onAction = viewModel::retrySearch)
                }
                state.searching -> items(SKELETON_ROWS) { SkeletonRow(round = true) }
                results == null && recent.isNotEmpty() -> {
                    item { SectionHeader("Recent places", Modifier.padding(horizontal = Gutter)) }
                    items(recent) { place -> ListRow(place.title, onClick = { viewModel.choosePlace(place) }, leading = { PlaceIcon(TablerIcons.History) }) }
                }
                results == null -> if (!pickupActive) item {
                    EmptyState(TablerIcons.Search, "Where are you going?", "Type a street, estate or landmark.")
                }
                results.isEmpty() -> item { EmptyState(TablerIcons.Search, "No places found", "Try a nearby landmark or street name.") }
                else -> items(results) { place ->
                    ListRow(
                        place.title,
                        supporting = place.detail.takeIf { it.isNotEmpty() && it != place.title },
                        onClick = { viewModel.choosePlace(place) },
                        leading = { PlaceIcon(TablerIcons.MapPin) },
                    )
                }
            }
        }
    }
}

/** One end of the trip. Both look the same; the one being typed in gets a teal outline. */
@Composable
private fun TripField(
    label: String,
    pickup: Boolean,
    active: Boolean,
    value: String,
    onValueChange: (String) -> Unit,
    focus: FocusRequester,
    onActivate: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val text = MaterialTheme.typography.bodyLarge
    Row(
        Modifier.fillMaxWidth().height(Size.tallField).clip(Corners.lg)
            .background(colors.surfaceContainerLow)
            .border(FocusBorder, if (active) colors.secondary else Color.Transparent, Corners.lg)
            .clickable(enabled = !active, onClick = onActivate)
            .padding(start = Space.lg, end = Space.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RouteNode(pickup)
        Spacer(Modifier.width(Space.md))
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant)
            if (active) {
                BasicTextField(
                    value = value,
                    onValueChange = onValueChange,
                    singleLine = true,
                    textStyle = text.copy(color = colors.onSurface),
                    cursorBrush = SolidColor(colors.secondary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    decorationBox = { field ->
                        if (value.isEmpty()) Text(if (pickup) "Search for your pickup" else "Search a street or landmark", style = text, color = colors.onSurfaceVariant)
                        field()
                    },
                    modifier = Modifier.fillMaxWidth().focusRequester(focus),
                )
            } else {
                Text(value.ifEmpty { "Not set" }, style = text, color = if (value.isEmpty()) colors.onSurfaceVariant else colors.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (active && value.isNotEmpty()) {
            IconButton(onClick = { onValueChange("") }) { Icon(TablerIcons.X, "Clear", Modifier.size(Size.smallIcon), tint = colors.onSurfaceVariant) }
        } else {
            Spacer(Modifier.width(Space.md))
        }
    }
}

@Composable
private fun PlaceIcon(icon: ImageVector, highlight: Boolean = false) {
    val colors = MaterialTheme.colorScheme
    Box(Modifier.size(Size.touch).clip(CircleShape).background(if (highlight) colors.primaryContainer else colors.surfaceContainerHigh), contentAlignment = Alignment.Center) {
        Icon(icon, null, Modifier.size(Size.icon), tint = if (highlight) colors.onPrimaryContainer else colors.onSurfaceVariant)
    }
}

/** The rider's past destinations that have a name, newest first, each once. */
internal fun recentPlaces(state: HomeUiState, limit: Int = RECENT_PLACES): List<Place> = state.recent.orEmpty()
    .mapNotNull { trip ->
        val point = trip.dropoff ?: return@mapNotNull null
        val name = state.names[trip.id] ?: return@mapNotNull null
        Place(name, "", point)
    }
    .distinctBy { it.title }
    .take(limit)

private const val SKELETON_ROWS = 4
private const val RECENT_PLACES = 5
private val FocusBorder = 2.dp
