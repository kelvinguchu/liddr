package com.liddr.app.data

import android.content.Context
import com.google.android.gms.tasks.Task
import com.google.android.libraries.places.api.Places
import com.google.android.libraries.places.api.model.AutocompleteSessionToken
import com.google.android.libraries.places.api.model.Place as GooglePlace
import com.google.android.libraries.places.api.net.FetchPlaceRequest
import com.google.android.libraries.places.api.net.FindAutocompletePredictionsRequest
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/** Finds places in Kenya with Google Places, which knows far more Nairobi landmarks than the phone does. */
class GooglePlaceFinder(context: Context, key: String) : PlaceFinder {
    private val client = run {
        if (!Places.isInitialized()) Places.initializeWithNewPlacesApiEnabled(context.applicationContext, key)
        Places.createClient(context.applicationContext)
    }
    private var session = AutocompleteSessionToken.newInstance()

    override fun startSession() {
        session = AutocompleteSessionToken.newInstance()
    }

    override suspend fun search(query: String): List<Place> {
        val request = FindAutocompletePredictionsRequest.builder()
            .setQuery(query)
            .setCountries("KE")
            .setSessionToken(session)
            .build()
        val response = try {
            client.findAutocompletePredictions(request).await()
        } catch (e: Exception) {
            throw PlaceSearchUnavailable()
        }
        return response.autocompletePredictions.map {
            Place(title = it.getPrimaryText(null).toString(), detail = it.getFullText(null).toString(), point = null, id = it.placeId)
        }
    }

    override suspend fun resolve(place: Place): Place {
        val id = place.id ?: return place
        val request = FetchPlaceRequest.builder(id, listOf(GooglePlace.Field.LOCATION)).setSessionToken(session).build()
        val found = try {
            client.fetchPlace(request).await().place.location
        } catch (e: Exception) {
            throw PlaceSearchUnavailable()
        } ?: throw PlaceSearchUnavailable()
        startSession() // Choosing a place ends Google's billing session.
        return place.copy(point = Coordinates(found.latitude, found.longitude))
    }
}

private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { waiter ->
    addOnSuccessListener { waiter.resume(it) }
    addOnFailureListener { waiter.resumeWithException(it) }
    addOnCanceledListener { waiter.cancel() }
}
