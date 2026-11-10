package com.liddr.app.data

import android.annotation.SuppressLint
import android.content.Context
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import androidx.core.os.CancellationSignal
import java.io.IOException
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

data class Place(val title: String, val detail: String, val point: Coordinates)

class PlaceSearchUnavailable : Exception("Place search isn't available right now. Please try again.")

/** Finds places in Kenya by name, using the search built into the phone. */
class PlaceFinder(context: Context) {
    private val geocoder = Geocoder(context.applicationContext, Locale("en", "KE"))

    @Suppress("DEPRECATION") // The callback version needs Android 13, and the app supports older phones.
    suspend fun search(query: String): List<Place> = withContext(Dispatchers.IO) {
        if (!Geocoder.isPresent()) throw PlaceSearchUnavailable()
        val found = try {
            geocoder.getFromLocationName(query, MAX_RESULTS, SOUTH, WEST, NORTH, EAST)
        } catch (e: IOException) {
            throw PlaceSearchUnavailable()
        }
        found.orEmpty().map { address ->
            val line = address.getAddressLine(0).orEmpty()
            Place(
                title = address.featureName?.takeUnless { it.isBlank() || it.all(Char::isDigit) } ?: line.substringBefore(','),
                detail = line,
                point = Coordinates(address.latitude, address.longitude),
            )
        }
    }

    private companion object {
        const val MAX_RESULTS = 6
        const val SOUTH = -4.9
        const val WEST = 33.9
        const val NORTH = 5.1
        const val EAST = 41.95
    }
}

/** Gets the phone's position once. The app does not track riders in the background. */
class Locator(context: Context) {
    private val app = context.applicationContext
    private val manager = app.getSystemService(LocationManager::class.java)

    /** Returns the position, or null if the phone could not get one in time. */
    @SuppressLint("MissingPermission") // The screen asks for permission before calling this.
    suspend fun current(): Coordinates? {
        val provider = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .firstOrNull { manager.isProviderEnabled(it) } ?: return null
        val fix = suspendCancellableCoroutine<Location?> { waiter ->
            val signal = CancellationSignal()
            waiter.invokeOnCancellation { signal.cancel() }
            LocationManagerCompat.getCurrentLocation(manager, provider, signal, ContextCompat.getMainExecutor(app)) {
                if (waiter.isActive) waiter.resume(it)
            }
        }
        return fix?.let { Coordinates(it.latitude, it.longitude) }
    }
}
