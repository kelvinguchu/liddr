package com.liddr.app.ui.driver

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.liddr.app.data.Offer
import com.liddr.app.ui.booking.kilometres
import com.liddr.app.ui.booking.money
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.kit.EmptyState
import com.liddr.app.ui.kit.LiddrCard
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.kit.Overline
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.SecondaryButton
import com.liddr.app.ui.kit.SectionHeader
import com.liddr.app.ui.kit.Space
import compose.icons.TablerIcons
import compose.icons.tablericons.Car

/** Online or not, any trip on offer, and what the driver has earned. */
@Composable
internal fun DriverHomeScreen(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit) {
    val context = LocalContext.current
    val colors = MaterialTheme.colorScheme
    val online = state.profile?.isOnline == true
    var refused by rememberSaveable { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        if (results[Manifest.permission.ACCESS_FINE_LOCATION] == true || results[Manifest.permission.ACCESS_COARSE_LOCATION] == true) viewModel.goOnline() else refused = true
    }
    DriverPage(
        title = if (online) "You're online" else "You're offline",
        onAccount = onAccount,
        body = if (online) "Keep Liddr open, and trips near you appear here." else "Go online to start getting trips.",
        bottom = {
            if (online) {
                SecondaryButton("Go offline", onClick = viewModel::goOffline, enabled = !state.busy)
            } else {
                PrimaryButton("Go online", busy = state.busy, enabled = !state.busy, onClick = {
                    if (hasLocation(context)) {
                        viewModel.goOnline()
                    } else {
                        val wanted = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) wanted += Manifest.permission.POST_NOTIFICATIONS
                        ask.launch(wanted.toTypedArray())
                    }
                })
            }
        },
    ) {
        if (refused && !online) {
            Text("Liddr needs your location to send you trips. Turn it on in Settings.", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = Space.md))
            LinkButton("Open Settings", { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))) })
        }
        if (online) {
            SectionHeader("Trips on offer")
            if (state.offers.isEmpty()) {
                EmptyState(TablerIcons.Car, "No trips yet", "Offers last a few seconds, so they appear here the moment one comes in.")
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(Space.sm)) { state.offers.forEach { OfferCard(it, state.busy, viewModel) } }
            }
        }
        state.earnings?.let { earnings ->
            SectionHeader("Earnings")
            Row(horizontalArrangement = Arrangement.spacedBy(Space.sm)) {
                EarningsCard("Today", earnings.today.totalKes, earnings.today.trips, Modifier.weight(1f))
                EarningsCard("This week", earnings.thisWeek.totalKes, earnings.thisWeek.trips, Modifier.weight(1f))
            }
        }
    }
}

private fun hasLocation(context: Context) =
    ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

@Composable
private fun EarningsCard(title: String, kes: Int, trips: Int, modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    LiddrCard(modifier) {
        Column(Modifier.padding(Space.lg)) {
            Overline(title)
            Text(money(kes), style = MaterialTheme.typography.headlineSmall, color = colors.onSurface, modifier = Modifier.padding(top = Space.xs))
            Text(if (trips == 1) "1 trip" else "$trips trips", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
        }
    }
}

/** A trip on offer: the fare first, how far the pickup is, then Accept. */
@Composable
private fun OfferCard(offer: Offer, busy: Boolean, viewModel: DriverViewModel) {
    val colors = MaterialTheme.colorScheme
    Surface(shape = Corners.lg, color = colors.surfaceContainerLow, border = BorderStroke(OfferBorder, colors.secondary), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(Space.lg)) {
            Row(verticalAlignment = Alignment.Bottom) {
                Column(Modifier.weight(1f)) {
                    Overline("New trip")
                    Text(money(offer.fareKes), style = MaterialTheme.typography.headlineSmall, color = colors.onSurface)
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text("Pickup ${kilometres(offer.distanceToPickupM)} away", style = MaterialTheme.typography.bodyMedium, color = colors.onSurface)
                    offer.riderRating?.let { Text("Rider ★ %.1f".format(it), style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant) }
                }
            }
            Spacer(Modifier.height(Space.lg))
            Row(horizontalArrangement = Arrangement.spacedBy(Space.md)) {
                SecondaryButton("Decline", onClick = { viewModel.reject(offer) }, enabled = !busy, modifier = Modifier.weight(1f))
                PrimaryButton("Accept", onClick = { viewModel.accept(offer) }, enabled = !busy, modifier = Modifier.weight(1f))
            }
        }
    }
}

private val OfferBorder = 2.dp
