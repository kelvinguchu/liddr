package com.liddr.app.data

import android.annotation.SuppressLint
import android.content.Context
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import android.os.CancellationSignal
import java.io.IOException
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** A place. Search results from Google Places carry an [id] and get their point when chosen. */
data class Place(val title: String, val detail: String, val point: Coordinates?, val id: String? = null)

/** Finds places by name. */
interface PlaceFinder {
    suspend fun search(query: String): List<Place>

    /** Fills in the point of a chosen place. */
    suspend fun resolve(place: Place): Place = place

    /** Starts a new search, which Google bills as one session however many letters are typed. */
    fun startSession() = Unit
}

class PlaceSearchUnavailable : Exception("Place search isn't available right now. Please try again.")

/** The address under a place's name, without the name repeated at its start. */
internal fun placeDetail(title: String, full: String): String =
    if (full.equals(title, ignoreCase = true)) "" else full.removePrefixIgnoringCase("$title, ")

private fun String.removePrefixIgnoringCase(prefix: String) = if (startsWith(prefix, ignoreCase = true)) substring(prefix.length) else this

/**
 * Runs a call to a place provider, turning its failures into [PlaceSearchUnavailable].
 * Cancellation passes through: a search replaced by the next keystroke is not an outage.
 */
internal suspend fun <T> placeLookup(call: suspend () -> T): T = try {
    call()
} catch (e: CancellationException) {
    throw e
} catch (e: Exception) {
    throw PlaceSearchUnavailable()
}

/** Finds places in Kenya using the search built into the phone. It needs no key, but knows fewer landmarks. */
class GeocoderPlaceFinder(context: Context) : PlaceFinder {
    private val geocoder = Geocoder(context.applicationContext, Locale.Builder().setLanguage("en").setRegion("KE").build())

    @Suppress("DEPRECATION") // The callback version needs Android 13, and the app supports older phones.
    override suspend fun search(query: String): List<Place> = withContext(Dispatchers.IO) {
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

/** Names the street at a point, using the lookup built into the phone. */
class AddressLookup(context: Context) {
    private val geocoder = Geocoder(context.applicationContext, Locale.Builder().setLanguage("en").setRegion("KE").build())

    /** Returns the place at [point], or null when the phone has no name for it. */
    @Suppress("DEPRECATION") // The callback version needs Android 13, and the app supports older phones.
    suspend fun describe(point: Coordinates): Place? = withContext(Dispatchers.IO) {
        if (!Geocoder.isPresent()) return@withContext null
        val address = try {
            geocoder.getFromLocation(point.lat, point.lng, 1)?.firstOrNull()
        } catch (e: IOException) {
            null
        } ?: return@withContext null
        val line = address.getAddressLine(0).orEmpty()
        // Plus Codes such as "QVCH+MCG" mean nothing to riders, so fall back to the area.
        val area = (address.subLocality ?: address.locality)?.takeIf(String::isNotBlank)
        val title = address.thoroughfare?.takeIf(String::isNotBlank)
            ?: address.featureName?.takeUnless { it.isBlank() || it.all(Char::isDigit) || '+' in it }
            ?: area?.let { "Near $it" }
            ?: line.split(',').map(String::trim).firstOrNull { it.isNotEmpty() && '+' !in it }
        title?.let { Place(it, line.split(',').map(String::trim).filterNot { part -> '+' in part }.joinToString(", "), point) }
    }
}

/** Gets the phone's position once. The app does not track riders in the background. */
class Locator(context: Context) {
    private val app = context.applicationContext
    private val manager = app.getSystemService(LocationManager::class.java)

    /** Returns the position, or null if no provider could get one in time. */
    @SuppressLint("MissingPermission") // The screen asks for permission before calling this.
    suspend fun current(): Coordinates? {
        for (provider in locationProviders(manager.getProviders(true))) {
            val fix = withTimeoutOrNull(PROVIDER_WAIT_MS) { fixFrom(provider) }
            if (fix != null) return Coordinates(fix.latitude, fix.longitude)
        }
        return null
    }

    @SuppressLint("MissingPermission")
    private suspend fun fixFrom(provider: String): Location? = suspendCancellableCoroutine { waiter ->
        val signal = CancellationSignal()
        waiter.invokeOnCancellation { signal.cancel() }
        LocationManagerCompat.getCurrentLocation(manager, provider, signal, ContextCompat.getMainExecutor(app)) {
            if (waiter.isActive) waiter.resume(it)
        }
    }

    private companion object {
        const val PROVIDER_WAIT_MS = 10_000L
    }
}

/**
 * The enabled providers to ask for a position, best first. Fused and network
 * answer from Wi-Fi and cell towers in seconds; GPS can take minutes indoors or
 * never answer, so it comes last.
 */
internal fun locationProviders(enabled: Collection<String>): List<String> =
    listOf(FUSED_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER).filter { it in enabled }

// LocationManager.FUSED_PROVIDER, which the SDK only names from Android 12.
private const val FUSED_PROVIDER = "fused"
