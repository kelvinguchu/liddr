package com.liddr.app.ui.booking

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.liddr.app.ui.launch.AuthError
import com.liddr.app.ui.launch.AuthPrimaryButton
import com.liddr.app.ui.launch.AuthProgress
import com.liddr.app.ui.launch.LiddrLogo
import com.liddr.app.ui.launch.OnboardingBackground
import compose.icons.TablerIcons
import compose.icons.tablericons.CurrentLocation
import compose.icons.tablericons.MapPin

@Composable
fun BookingRoot(viewModel: BookingViewModel, onAccount: () -> Unit) {
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
    BackHandler(enabled = state.stage == Stage.SEARCH || state.stage == Stage.OPTIONS, onBack = viewModel::back)
    when (state.stage) {
        Stage.RESUMING -> Page { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { AuthProgress() } }
        Stage.HOME -> HomeScreen(state, viewModel, onAccount)
        Stage.SEARCH -> SearchScreen(state, viewModel)
        Stage.OPTIONS -> OptionsScreen(state, viewModel)
        Stage.TRIP -> TripScreen(state, viewModel)
        Stage.RATE -> Page {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                Spacer(Modifier.height(40.dp))
                Heading("How was your last trip?")
                Spacer(Modifier.height(16.dp))
                RatingForm(state.busy, state.error, onSubmit = viewModel::submitRating, onSkip = viewModel::skipRating)
            }
        }
    }
}

@Composable
internal fun Page(content: @Composable ColumnScope.() -> Unit) {
    OnboardingBackground {
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding().padding(horizontal = 24.dp, vertical = 10.dp),
            content = content,
        )
    }
}

@Composable
internal fun Heading(text: String) {
    Text(text, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onBackground)
}

@Composable
internal fun BodyText(text: String) {
    Text(text, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun PlaceRow(icon: ImageVector, label: String, value: String, placeholder: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(onClick = onClick, shape = RoundedCornerShape(16.dp), color = colors.surface, border = BorderStroke(1.dp, colors.outlineVariant), modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, Modifier.size(22.dp), tint = colors.primary)
            Spacer(Modifier.width(14.dp))
            Column {
                Text(label, style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant)
                Text(value, style = MaterialTheme.typography.titleMedium, color = if (placeholder) colors.onSurfaceVariant else colors.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun HomeScreen(state: BookingUiState, viewModel: BookingViewModel, onAccount: () -> Unit) {
    val context = LocalContext.current
    fun granted() = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
    var refused by rememberSaveable { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        if (results.values.any { it }) viewModel.useCurrentLocation() else refused = true
    }
    LaunchedEffect(Unit) { if (state.pickup == null && granted()) viewModel.useCurrentLocation() }

    Page {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            LiddrLogo(Modifier.width(120.dp))
            TextButton(onClick = onAccount) { Text("Account") }
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            Spacer(Modifier.height(28.dp))
            Heading("Where to?")
            Spacer(Modifier.height(20.dp))
            PlaceRow(
                icon = TablerIcons.CurrentLocation,
                label = "Pickup",
                value = state.pickup?.title ?: if (state.locating) "Finding your location…" else "Enter pickup",
                placeholder = state.pickup == null,
                onClick = { viewModel.openSearch(SearchTarget.PICKUP) },
            )
            Spacer(Modifier.height(12.dp))
            PlaceRow(
                icon = TablerIcons.MapPin,
                label = "Destination",
                value = state.dropoff?.title ?: "Enter destination",
                placeholder = state.dropoff == null,
                onClick = { viewModel.openSearch(SearchTarget.DROPOFF) },
            )
            AuthError(state.locationError)
            if (state.pickup == null && !state.locating) {
                Spacer(Modifier.height(12.dp))
                if (refused) {
                    BodyText("Location is off for Liddr. You can turn it on in Settings, or type your pickup above.")
                    TextButton(onClick = {
                        context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
                    }) { Text("Open Settings") }
                } else {
                    TextButton(onClick = {
                        if (granted()) viewModel.useCurrentLocation()
                        else ask.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                    }) { Text("Use my location") }
                }
            }
        }
    }
}

@Composable
private fun SearchScreen(state: BookingUiState, viewModel: BookingViewModel) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    val colors = MaterialTheme.colorScheme
    Page {
        TextButton(onClick = viewModel::back) { Text("Back") }
        Spacer(Modifier.height(8.dp))
        Heading(if (state.target == SearchTarget.PICKUP) "Where should we pick you up?" else "Where are you going?")
        Spacer(Modifier.height(16.dp))
        OutlinedTextField(
            value = state.query,
            onValueChange = viewModel::onQueryChanged,
            placeholder = { Text("Search a street or landmark") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            modifier = Modifier.fillMaxWidth().focusRequester(focus),
        )
        AuthError(state.searchError)
        Spacer(Modifier.height(8.dp))
        val results = state.results
        when {
            state.searching -> Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { AuthProgress() }
            results != null && results.isEmpty() -> Text("No places found. Try a nearby landmark or street name.", color = colors.onSurfaceVariant, modifier = Modifier.padding(vertical = 16.dp))
            results != null -> LazyColumn(Modifier.weight(1f)) {
                items(results) { place ->
                    Column(Modifier.fillMaxWidth().clickable { viewModel.choosePlace(place) }.padding(vertical = 12.dp)) {
                        Text(place.title, style = MaterialTheme.typography.titleMedium, color = colors.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (place.detail.isNotEmpty() && place.detail != place.title) {
                            Text(place.detail, style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun OptionsScreen(state: BookingUiState, viewModel: BookingViewModel) {
    val colors = MaterialTheme.colorScheme
    val chosen = state.options.firstOrNull { it.category.slug == state.selected }
    Page {
        TextButton(onClick = viewModel::back) { Text("Back") }
        Spacer(Modifier.height(8.dp))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            Heading("Choose your ride")
            Spacer(Modifier.height(4.dp))
            BodyText("To ${state.dropoff?.title.orEmpty()}")
            Spacer(Modifier.height(18.dp))
            when {
                state.optionsLoading -> Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { AuthProgress() }
                state.options.isEmpty() -> {
                    Text(state.error ?: "No rides are available for this trip right now.", color = colors.onSurfaceVariant)
                    TextButton(onClick = viewModel::loadOptions) { Text("Try again") }
                }
                else -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    state.options.forEach { option -> OptionCard(option, option.category.slug == state.selected) { viewModel.select(option.category.slug) } }
                    if (chosen != null && chosen.quote.surgeBps > NO_SURGE) {
                        BodyText("High demand: prices are ${formatSurge(chosen.quote.surgeBps)}× the usual fare right now.")
                    }
                    if (state.error != null) AuthError(state.error)
                }
            }
        }
        if (state.options.isNotEmpty()) {
            Text("Pay your driver directly with cash or M-Pesa.", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant, modifier = Modifier.padding(bottom = 10.dp))
            AuthPrimaryButton("Book ${chosen?.category?.label.orEmpty()}", enabled = chosen != null && !state.busy, busy = state.busy, onClick = viewModel::book)
        }
    }
}

@Composable
private fun OptionCard(option: RideOption, selected: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        color = colors.surface,
        border = BorderStroke(if (selected) 2.dp else 1.dp, if (selected) colors.primary else colors.outlineVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(option.category.label, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.onSurface)
                Text("${minutes(option.quote.durationS)} · ${kilometres(option.quote.distanceM)}", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
            }
            Text(money(option.quote.fareKes), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = colors.onSurface)
        }
    }
}

internal const val NO_SURGE = 10_000
