package com.liddr.app.ui.booking

import com.liddr.app.ui.kit.Thumbnail
import com.liddr.app.ui.kit.EmptyState
import compose.icons.tablericons.WifiOff
import com.liddr.app.ui.kit.RouteNode
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Corners
import com.liddr.app.R
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.foundation.Image
import androidx.annotation.DrawableRes
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.draw.drawBehind
import androidx.core.content.ContextCompat
import com.liddr.app.data.canShare
import com.liddr.app.ui.kit.CircleButton
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.kit.MapSheet
import com.liddr.app.ui.kit.Overline
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.launch.AuthError
import com.liddr.app.ui.launch.AuthProgress
import compose.icons.TablerIcons
import compose.icons.tablericons.Car
import compose.icons.tablericons.Cash
import compose.icons.tablericons.ChevronLeft
import compose.icons.tablericons.CurrentLocation
import compose.icons.tablericons.MapPin
import compose.icons.tablericons.Motorbike
import compose.icons.tablericons.Package
import compose.icons.tablericons.Search
import compose.icons.tablericons.User

/** The route on the map; every ride with its fare, and one Book button. */
@Composable
internal fun OptionsScreen(state: BookingUiState, viewModel: BookingViewModel) {
    val colors = MaterialTheme.colorScheme
    val chosen = state.options.firstOrNull { it.category.slug == state.selected }
    var sheet by remember { mutableStateOf(0) }
    val density = LocalDensity.current
    Box(Modifier.fillMaxSize()) {
        MapBackdrop(state.pickup?.point, state.dropoff?.point, null, chosen?.quote?.polyline, with(density) { sheet.toDp() })
        CircleButton(TablerIcons.ChevronLeft, "Back", viewModel::back, Modifier.statusBarsPadding().padding(Gutter))
        MapSheet(Modifier.align(Alignment.BottomCenter).onSizeChanged { sheet = it.height }) {
            Column(Modifier.navigationBarsPadding()) {
                Text("Choose a ride", style = MaterialTheme.typography.titleLarge, color = colors.onSurface, modifier = Modifier.padding(start = Gutter, end = Gutter, top = Space.lg, bottom = Space.sm))
                Text("To ${state.dropoff?.title.orEmpty()}", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, modifier = Modifier.padding(horizontal = Gutter), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(Space.sm))
                Column(Modifier.heightIn(max = RideListMax).verticalScroll(rememberScrollState())) {
                    when {
                        state.optionsLoading -> Box(Modifier.fillMaxWidth().padding(Space.xxl), contentAlignment = Alignment.Center) { AuthProgress() }
                        state.options.isEmpty() && state.error != null ->
                            EmptyState(TablerIcons.WifiOff, "We couldn't get prices", state.error, actionLabel = "Try again", onAction = viewModel::loadOptions)
                        state.options.isEmpty() ->
                            EmptyState(TablerIcons.Car, "No rides available", "Nobody can take this trip right now. Try again in a few minutes.", actionLabel = "Try again", onAction = viewModel::loadOptions)
                        else -> state.options.forEach { option -> RideRow(option, option.category.slug == state.selected) { viewModel.select(option.category.slug) } }
                    }
                }
                if (chosen != null && canShare(chosen.category)) {
                    val shared = state.sharedQuote
                    val saving = shared?.soloFareKes?.let { it - shared.fareKes }
                    Row(
                        Modifier.fillMaxWidth().toggleable(value = state.sharing, enabled = !state.busy, role = Role.Switch, onValueChange = viewModel::setSharing).padding(horizontal = Gutter, vertical = Space.sm),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("Share with one other rider", style = MaterialTheme.typography.titleSmall, color = colors.onSurface)
                            Text(
                                if (state.sharing && shared != null && saving != null) "You pay ${money(shared.fareKes)}, saving ${money(saving)}." else "Pay less by sharing the car on the way.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = colors.onSurfaceVariant,
                            )
                        }
                        Switch(checked = state.sharing, onCheckedChange = null)
                    }
                }
                HorizontalDivider(color = colors.outlineVariant, modifier = Modifier.padding(top = Space.sm))
                Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(Space.md)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(TablerIcons.Cash, null, Modifier.size(Size.icon), tint = colors.onSurface)
                        Spacer(Modifier.width(Space.md))
                        Text("Cash or M-Pesa", style = MaterialTheme.typography.titleSmall, color = colors.onSurface)
                        Text(" · pay your driver", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                    }
                    val fare = (state.sharedQuote?.takeIf { state.sharing } ?: chosen?.quote)?.fareKes
                    val label = when {
                        chosen == null -> "Book"
                        chosen.category.slug == "send" -> "Continue"
                        else -> "Book ${chosen.category.label}${fare?.let { " · ${money(it)}" }.orEmpty()}"
                    }
                    PrimaryButton(label, onClick = viewModel::book, enabled = chosen != null, busy = state.busy)
                }
            }
        }
    }
}

@Composable
private fun RideRow(option: RideOption, selected: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val seats = option.category.capacity.takeIf { it > 0 }?.let { if (it == 1) "1 seat" else "$it seats" }
    Row(
        Modifier.fillMaxWidth()
            .background(if (selected) colors.secondaryContainer else colors.surface)
            // The chosen ride carries the teal stripe down its leading edge.
            .drawBehind { if (selected) drawRect(colors.secondary, size = androidx.compose.ui.geometry.Size(ChosenStripe.toPx(), size.height)) }
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .heightIn(min = Size.tallRow)
            .padding(horizontal = Gutter, vertical = Space.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Thumbnail { VehicleArt(option.category.slug, Size.art) }
        Spacer(Modifier.width(Space.md))
        Column(Modifier.weight(1f)) {
            Text(option.category.label, style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
            Text(listOfNotNull(minutes(option.quote.durationS), seats).joinToString(" · "), style = MaterialTheme.typography.bodyMedium, color = if (selected) colors.onSurface else colors.onSurfaceVariant)
        }
        Text(money(option.quote.fareKes), style = MaterialTheme.typography.titleLarge, color = colors.onSurface)
    }
}

/** The 3D illustration for a vehicle type, or null for a type without one yet. */
@DrawableRes
internal fun vehicleArt(slug: String): Int? = when (slug) {
    "motorbike" -> R.drawable.vehicle_motorbike
    "electric_motorbike" -> R.drawable.vehicle_electric_motorbike
    "basic" -> R.drawable.vehicle_basic
    "comfort" -> R.drawable.vehicle_comfort
    "xl" -> R.drawable.vehicle_xl
    "women_only" -> R.drawable.vehicle_women_only
    "green" -> R.drawable.vehicle_green
    "send" -> R.drawable.vehicle_send
    else -> null
}

/** A vehicle type's illustration, or its icon when it has none. */
@Composable
internal fun VehicleArt(slug: String, size: Dp, modifier: Modifier = Modifier) {
    val art = vehicleArt(slug)
    if (art != null) {
        Image(painterResource(art), contentDescription = null, contentScale = ContentScale.Fit, modifier = modifier.size(size))
    } else {
        Icon(vehicleIcon(slug), null, modifier.size(size * 0.6f), tint = MaterialTheme.colorScheme.onSurface)
    }
}

internal fun vehicleIcon(slug: String): ImageVector = when (slug) {
    "motorbike", "electric_motorbike" -> TablerIcons.Motorbike
    "send" -> TablerIcons.Package
    else -> TablerIcons.Car
}

private val RideListMax = 300.dp
private val ChosenStripe = 4.dp
