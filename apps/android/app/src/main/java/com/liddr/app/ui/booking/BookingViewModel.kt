package com.liddr.app.ui.booking

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.liddr.app.data.Coordinates
import com.liddr.app.data.LiddrApi
import com.liddr.app.data.Locator
import com.liddr.app.data.OfflineException
import com.liddr.app.data.Place
import com.liddr.app.data.PlaceFinder
import com.liddr.app.data.PlaceSearchUnavailable
import com.liddr.app.data.ProblemException
import com.liddr.app.data.Quote
import com.liddr.app.data.Ride
import com.liddr.app.data.RideStatus
import com.liddr.app.data.VehicleCategory
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class Stage { RESUMING, HOME, SEARCH, OPTIONS, TRIP, RATE }

enum class SearchTarget { PICKUP, DROPOFF }

data class RideOption(val category: VehicleCategory, val quote: Quote)

data class BookingUiState(
    val stage: Stage = Stage.RESUMING,
    val pickup: Place? = null,
    val dropoff: Place? = null,
    val locating: Boolean = false,
    val locationError: String? = null,
    val target: SearchTarget = SearchTarget.DROPOFF,
    val query: String = "",
    val searching: Boolean = false,
    val results: List<Place>? = null,
    val searchError: String? = null,
    val optionsLoading: Boolean = false,
    val options: List<RideOption> = emptyList(),
    val selected: String? = null,
    val busy: Boolean = false,
    val error: String? = null,
    val ride: Ride? = null,
    val reconnecting: Boolean = false,
    val driverPhoto: ByteArray? = null,
    val ratingRideId: String? = null,
)

class BookingViewModel(
    private val api: LiddrApi,
    private val places: PlaceFinder,
    private val locator: Locator,
) : ViewModel() {
    private val _ui = MutableStateFlow(BookingUiState())
    val ui: StateFlow<BookingUiState> = _ui.asStateFlow()

    private var searchJob: Job? = null
    private var pollJob: Job? = null
    private var visible = false

    init {
        viewModelScope.launch {
            val active = runCatching { api.findActiveRide() }.getOrNull()
            if (active != null) {
                showRide(active)
                return@launch
            }
            // A trip that ended while the app was closed still gets its rating.
            val owed = runCatching { api.listPendingRatings() }.getOrNull()?.firstOrNull { it.raterRole == "rider" }
            _ui.update {
                if (owed != null) it.copy(stage = Stage.RATE, ratingRideId = owed.rideId) else it.copy(stage = Stage.HOME)
            }
        }
    }

    fun useCurrentLocation() {
        if (_ui.value.locating) return
        _ui.update { it.copy(locating = true, locationError = null) }
        viewModelScope.launch {
            val point = runCatching { locator.current() }.getOrNull()
            _ui.update {
                if (point != null) {
                    it.copy(locating = false, pickup = Place(CURRENT_LOCATION, "", point))
                } else {
                    it.copy(locating = false, locationError = "We couldn't find your location. Check that location is on, or enter your pickup.")
                }
            }
        }
    }

    fun openSearch(target: SearchTarget) {
        _ui.update { it.copy(stage = Stage.SEARCH, target = target, query = "", results = null, searchError = null, searching = false) }
    }

    fun back() {
        searchJob?.cancel()
        _ui.update {
            when (it.stage) {
                Stage.SEARCH, Stage.OPTIONS -> it.copy(stage = Stage.HOME, error = null)
                else -> it
            }
        }
    }

    fun onQueryChanged(query: String) {
        _ui.update { it.copy(query = query, searchError = null) }
        searchJob?.cancel()
        if (query.trim().length < MIN_QUERY) {
            _ui.update { it.copy(results = null, searching = false) }
            return
        }
        searchJob = viewModelScope.launch {
            delay(SEARCH_DEBOUNCE_MS)
            _ui.update { it.copy(searching = true) }
            try {
                val found = places.search(query.trim())
                _ui.update { it.copy(results = found, searching = false) }
            } catch (e: PlaceSearchUnavailable) {
                _ui.update { it.copy(searchError = e.message, searching = false) }
            }
        }
    }

    fun choosePlace(place: Place) {
        searchJob?.cancel()
        val target = _ui.value.target
        _ui.update {
            if (target == SearchTarget.PICKUP) it.copy(pickup = place, stage = Stage.HOME, locationError = null) else it.copy(dropoff = place, stage = Stage.HOME)
        }
        val state = _ui.value
        if (state.pickup != null && state.dropoff != null) loadOptions()
    }

    fun loadOptions() {
        val state = _ui.value
        val pickup = state.pickup?.point ?: return
        val dropoff = state.dropoff?.point ?: return
        _ui.update { it.copy(stage = Stage.OPTIONS, optionsLoading = true, options = emptyList(), selected = null, error = null) }
        viewModelScope.launch {
            try {
                val options = fetchOptions(pickup, dropoff)
                _ui.update { it.copy(options = options, selected = options.firstOrNull()?.category?.slug) }
            } catch (e: ProblemException) {
                _ui.update { it.copy(error = e.message) }
            } catch (e: OfflineException) {
                _ui.update { it.copy(error = e.message) }
            } finally {
                _ui.update { it.copy(optionsLoading = false) }
            }
        }
    }

    fun select(slug: String) = _ui.update { it.copy(selected = slug) }

    fun book() {
        val state = _ui.value
        val quote = state.options.firstOrNull { it.category.slug == state.selected }?.quote ?: return
        if (state.busy) return
        act {
            try {
                showRide(api.bookRide(quote.id))
            } catch (e: ProblemException) {
                if (e.code == "QUOTE_EXPIRED" || e.code == "QUOTE_NOT_FOUND") {
                    loadOptions()
                    throw ProblemException(e.status, e.code, "That price expired. Here's the latest one.")
                }
                throw e
            }
        }
    }

    fun cancel(reason: String) {
        val id = _ui.value.ride?.id ?: return
        act { _ui.update { it.copy(ride = api.cancelRide(id, reason)) } }
    }

    /** Leaves a finished trip. The places stay, so booking again is quick. */
    fun finishTrip() {
        pollJob?.cancel()
        _ui.update { it.copy(stage = Stage.HOME, ride = null, driverPhoto = null, options = emptyList(), dropoff = null, error = null) }
    }

    fun submitRating(score: Int, tags: List<String>, comment: String) {
        val id = ratingTarget() ?: return
        if (_ui.value.busy) return
        finishRating { api.rateRide(id, score, tags, comment.trim().takeIf(String::isNotEmpty)) }
    }

    fun skipRating() {
        val id = ratingTarget() ?: return
        if (_ui.value.busy) return
        finishRating { api.skipRating(id) }
    }

    private fun ratingTarget() = _ui.value.ratingRideId ?: _ui.value.ride?.id

    private fun finishRating(block: suspend () -> Unit) = act {
        try {
            block()
        } catch (e: ProblemException) {
            // Already rated or past the deadline: nothing is left for the rider to do.
            if (e.code != "RATING_NOT_AVAILABLE" && e.code != "ALREADY_DONE") throw e
        }
        _ui.update { it.copy(ratingRideId = null) }
        finishTrip()
    }

    fun tryAgain() {
        pollJob?.cancel()
        _ui.update { it.copy(ride = null, driverPhoto = null) }
        loadOptions()
    }

    /** The trip is only followed while the rider can see it. */
    fun setVisible(isVisible: Boolean) {
        visible = isVisible
        if (isVisible) startPolling() else pollJob?.cancel()
    }

    private suspend fun fetchOptions(pickup: Coordinates, dropoff: Coordinates): List<RideOption> {
        val categories = api.listVehicleCategories().filter { it.capacity > 0 }
        var firstFailure: Exception? = null
        val priced = categories.map { category ->
            viewModelScope.async {
                try {
                    RideOption(category, api.createQuote(category.slug, pickup, dropoff))
                } catch (e: ProblemException) {
                    firstFailure = firstFailure ?: e
                    null
                } catch (e: OfflineException) {
                    firstFailure = firstFailure ?: e
                    null
                }
            }
        }.awaitAll().filterNotNull()
        if (priced.isEmpty()) firstFailure?.let { throw it }
        return priced
    }

    private fun showRide(ride: Ride) {
        _ui.update { it.copy(stage = Stage.TRIP, ride = ride, error = null) }
        loadPhoto(ride)
        if (visible) startPolling()
    }

    private fun startPolling() {
        pollJob?.cancel()
        if (_ui.value.ride?.let { RideStatus.isActive(it.status) } != true) return
        pollJob = viewModelScope.launch {
            while (true) {
                delay(POLL_MS)
                val id = _ui.value.ride?.id ?: return@launch
                try {
                    val ride = api.getRide(id)
                    _ui.update { it.copy(ride = ride, reconnecting = false) }
                    loadPhoto(ride)
                    if (!RideStatus.isActive(ride.status)) return@launch
                } catch (e: OfflineException) {
                    _ui.update { it.copy(reconnecting = true) }
                } catch (e: ProblemException) {
                    _ui.update { it.copy(reconnecting = true) }
                }
            }
        }
    }

    private fun loadPhoto(ride: Ride) {
        val url = ride.driver?.photoUrl ?: return
        if (_ui.value.driverPhoto != null) return
        viewModelScope.launch {
            val bytes = runCatching { api.download(url) }.getOrNull() ?: return@launch
            _ui.update { it.copy(driverPhoto = bytes) }
        }
    }

    private fun act(block: suspend () -> Unit) {
        _ui.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                block()
            } catch (e: ProblemException) {
                _ui.update { it.copy(error = e.message) }
            } catch (e: OfflineException) {
                _ui.update { it.copy(error = e.message) }
            } finally {
                _ui.update { it.copy(busy = false) }
            }
        }
    }

    private companion object {
        const val CURRENT_LOCATION = "Current location"
        const val MIN_QUERY = 3
        const val SEARCH_DEBOUNCE_MS = 400L
        const val POLL_MS = 3_000L
    }
}
