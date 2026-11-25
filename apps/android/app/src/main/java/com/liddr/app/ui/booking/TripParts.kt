package com.liddr.app.ui.booking

import androidx.compose.ui.semantics.semantics

import androidx.compose.ui.semantics.heading

import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.kit.Size
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.BitmapFactory
import android.view.WindowManager
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.liddr.app.data.DriverCard
import com.liddr.app.data.Ride
import com.liddr.app.data.distanceMetres
import com.liddr.app.ui.kit.Overline
import com.liddr.app.ui.kit.Panel
import com.liddr.app.ui.kit.Plate
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.theme.Teal
import com.liddr.app.ui.theme.White
import compose.icons.TablerIcons
import compose.icons.tablericons.Check

/** Every state of the trip sheet opens the same way: what is happening, then one line of detail. */
@Composable
internal fun SheetTitle(title: String, detail: String? = null) {
    val colors = MaterialTheme.colorScheme
    Text(title, style = MaterialTheme.typography.headlineSmall, color = colors.onSurface, modifier = Modifier.semantics { heading() })
    detail?.let { Text(it, style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = Space.xs)) }
}

/** Finding a driver: useful things to do while the request goes out. */
@Composable
internal fun WaitingChecklist(ride: Ride, pickupName: String, category: String?) {
    val colors = MaterialTheme.colorScheme
    SheetTitle(headline(ride.status), "Your driver's plate appears here the moment one accepts.")
    Spacer(Modifier.height(Space.md))
    LinearProgressIndicator(Modifier.fillMaxWidth(), color = colors.secondary, trackColor = colors.surfaceContainerHigh)
    Spacer(Modifier.height(Space.lg))
    Text("While you wait", style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
    Spacer(Modifier.height(Space.xs))
    CheckRow("Be at $pickupName", "So your driver doesn't have to search")
    CheckRow("Have ${money(ride.fareKes)} ready", "M-Pesa or cash, paid to your driver")
    if (category == "motorbike" || category == "electric_motorbike") CheckRow("Ask your rider for a helmet", "Safer on every boda trip")
}

@Composable
private fun CheckRow(title: String, detail: String) {
    val colors = MaterialTheme.colorScheme
    var done by rememberSaveable(title) { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().toggleable(value = done, role = Role.Checkbox, onValueChange = { done = it }).padding(vertical = Space.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(Size.icon).clip(CircleShape)
                .background(if (done) colors.secondary else colors.surface)
                .border(CheckBorder, if (done) colors.secondary else colors.outline, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (done) Icon(TablerIcons.Check, null, Modifier.size(Size.smallIcon), tint = colors.onSecondary)
        }
        Spacer(Modifier.width(Space.lg))
        Column {
            Text(title, style = MaterialTheme.typography.titleMedium, color = if (done) colors.onSurfaceVariant else colors.onSurface, textDecoration = if (done) TextDecoration.LineThrough else null)
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
        }
    }
}

/** A driver accepted: where to meet, and the plate to look for. */
@Composable
internal fun DriverComing(ride: Ride, pickupName: String, photo: ByteArray?) {
    val away = ride.driverLocation?.let { nearby(distanceMetres(it, ride.pickup).toInt()) }
    SheetTitle(headline(ride.status), listOfNotNull(away?.let { "$it away" }, "Meet at $pickupName").joinToString(" · "))
    ride.driver?.let { DriverPlate(it, photo) }
}

/** The driver is at the pickup: the plate, and a way to be seen. */
@Composable
internal fun DriverHere(ride: Ride, photo: ByteArray?, onFlash: () -> Unit) {
    val name = ride.driver?.name?.substringBefore(' ') ?: "Your driver"
    SheetTitle(headline(ride.status), "$name is waiting at your pickup.")
    ride.driver?.let { DriverPlate(it, photo) }
    Spacer(Modifier.height(Space.lg))
    PrimaryButton("Flash my screen so $name can spot me", onClick = onFlash)
}

/** On the ride: where you're going and how far is left. */
@Composable
internal fun OnTheRide(ride: Ride, dropoffName: String, photo: ByteArray?) {
    val left = ride.driverLocation?.let { "${kilometres(distanceMetres(it, ride.dropoff).toInt())} to go" }
    SheetTitle(headline(ride.status), listOfNotNull("To $dropoffName", left).joinToString(" · "))
    ride.driver?.let { DriverRow(it, photo, showPlate = true) }
}

/** Arrived: a receipt with what to pay the driver, then the rating. */
@Composable
internal fun Arrived(ride: Ride, dropoffName: String, state: BookingUiState, viewModel: BookingViewModel) {
    val colors = MaterialTheme.colorScheme
    val name = ride.driver?.name?.substringBefore(' ') ?: "your driver"
    SheetTitle(headline(ride.status), dropoffName)
    Spacer(Modifier.height(Space.lg))
    Panel {
        Overline("Pay $name directly")
        Text(money(ride.fareKes), style = MaterialTheme.typography.displaySmall, color = colors.onSurface)
        Text("M-Pesa or cash to the driver, not the app.", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
    }
    Spacer(Modifier.height(Space.lg))
    RatingForm(state.busy, onSubmit = viewModel::submitRating, onSkip = viewModel::skipRating)
}

/** The plate panel with the driver under it. */
@Composable
internal fun DriverPlate(driver: DriverCard, photo: ByteArray?) {
    Spacer(Modifier.height(Space.lg))
    Panel {
        Overline("Look for this plate", Modifier.align(Alignment.CenterHorizontally))
        Spacer(Modifier.height(Space.md))
        driver.plateNumber?.let { Plate(it, Modifier.align(Alignment.CenterHorizontally), large = true) }
        Spacer(Modifier.height(Space.sm))
        Text(vehicleName(driver.vehicleCategory), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.align(Alignment.CenterHorizontally))
    }
    DriverRow(driver, photo, showPlate = false)
}

@Composable
private fun DriverRow(driver: DriverCard, photo: ByteArray?, showPlate: Boolean) {
    val colors = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().padding(top = Space.lg), verticalAlignment = Alignment.CenterVertically) {
        DriverAvatar(driver.name, photo)
        Spacer(Modifier.width(Space.md))
        Column(Modifier.weight(1f)) {
            Text(driver.name ?: "Your driver", style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
            val rating = driver.rating?.let { "★ %.1f".format(it) } ?: "New driver"
            Text("$rating · ${driver.completedRides} trips", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
        }
        if (showPlate) driver.plateNumber?.let { Plate(it) }
    }
}

internal fun vehicleName(slug: String) = slug.replace('_', ' ').replaceFirstChar(Char::uppercase)

/**
 * The phone as a beacon: full teal, the plate, full brightness and the screen
 * kept on, until the rider taps to close it.
 */
@Composable
internal fun FlashScreen(driver: DriverCard, onClose: () -> Unit) {
    val activity = LocalContext.current.findActivity()
    DisposableEffect(activity) {
        val window = activity?.window
        val before = window?.attributes?.screenBrightness
        window?.let {
            it.attributes = it.attributes.apply { screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL }
            it.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        onDispose {
            window?.let {
                it.attributes = it.attributes.apply { screenBrightness = before ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE }
                it.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            // The livery teal on purpose: the driver looks for the colour of their own car.
            Modifier.fillMaxSize().background(Teal).clickable(onClick = onClose).padding(Space.xl),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Hold your phone up", style = MaterialTheme.typography.headlineMedium, color = White)
            Spacer(Modifier.height(Space.xl))
            driver.plateNumber?.let { Plate(it, large = true) }
            Spacer(Modifier.height(Space.lg))
            Text(driver.name ?: "Your driver", style = MaterialTheme.typography.titleLarge, color = White)
            Spacer(Modifier.height(Space.xxl))
            Text("Tap anywhere to close", style = MaterialTheme.typography.bodyLarge, color = White.copy(alpha = 0.85f))
        }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

@Composable
private fun DriverAvatar(name: String?, photo: ByteArray?) {
    val colors = MaterialTheme.colorScheme
    val image = remember(photo) { photo?.let(::decodeAvatar) }
    if (image != null) {
        Image(image, "Driver's photo", contentScale = ContentScale.Crop, modifier = Modifier.size(Size.touch).clip(CircleShape))
    } else {
        Box(Modifier.size(Size.touch).clip(CircleShape).background(colors.secondaryContainer), contentAlignment = Alignment.Center) {
            Text(name?.firstOrNull()?.uppercase() ?: "?", style = MaterialTheme.typography.titleLarge, color = colors.onSecondaryContainer)
        }
    }
}

/** Samples the selfie down, since a phone camera's full size would waste memory on a small circle. */
private fun decodeAvatar(bytes: ByteArray) = runCatching {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    var sample = 1
    while (bounds.outWidth / (sample * 2) >= AVATAR_PX && bounds.outHeight / (sample * 2) >= AVATAR_PX) sample *= 2
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
}.getOrNull()

private const val AVATAR_PX = 256

private val CheckBorder = 2.dp
