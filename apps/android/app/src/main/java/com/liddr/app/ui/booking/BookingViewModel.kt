package com.liddr.app.ui.booking

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.liddr.app.data.Coordinates
import com.liddr.app.data.Delivery
import com.liddr.app.data.DeliveryRequest
import com.liddr.app.data.LiddrApi
import com.liddr.app.data.Locator
import com.liddr.app.data.OfflineException
import com.liddr.app.data.Place
import com.liddr.app.data.PlaceFinder
import com.liddr.app.data.PlaceSearchUnavailable
import com.liddr.app.data.ProblemException
import com.liddr.app.data.Quote
import com.liddr.app.data.Realtime
import com.liddr.app.data.RealtimeEvent
import com.liddr.app.data.Ride
import com.liddr.app.data.RideStatus
import com.liddr.app.data.SendApi
import com.liddr.app.data.VehicleCategory
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class Stage { RESUMING, HOME, SEARCH, OPTIONS, SEND_DETAILS, TRIP, RATE }

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
    val delivery: Delivery? = null,
    val needsAcknowledgement: Boolean = false,
    val sharedQuote: Quote? = null,
    val sharing: Boolean = false,
)

class BookingViewModel(
    private val api: LiddrApi,
    private val send: SendApi,
    private val places: PlaceFinder,
    private val locator: Locator,
    private val realtime: Realtime,
) : ViewModel() {
    private val _ui = MutableStateFlow(BookingUiState())
    val ui: StateFlow<BookingUiState> = _ui.asStateFlow()

    private var searchJob: Job? = null
    private var pollJob: Job? = null
    private var visible = false

    init {
        viewModelScope.launch { realtime.events.collect(::onLive) }
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
        places.startSession()
        _ui.update { it.copy(stage = Stage.SEARCH, target = target, query = "", results = null, searchError = null, searching = false) }
    }

    fun back() {
        searchJob?.cancel()
        _ui.update {
            when (it.stage) {
                Stage.SEARCH, Stage.OPTIONS -> it.copy(stage = Stage.HOME, error = null)
                Stage.SEND_DETAILS -> it.copy(stage = Stage.OPTIONS, error = null, needsAcknowledgement = false)
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

    fun choosePlace(chosen: Place) {
        searchJob?.cancel()
        if (chosen.point == null) {
            _ui.update { it.copy(searching = true) }
            viewModelScope.launch {
                try {
                    choosePlace(places.resolve(chosen))
                } catch (e: PlaceSearchUnavailable) {
                    _ui.update { it.copy(searchError = e.message, searching = false) }
                }
            }
            return
        }
        val place = chosen
        _ui.update { it.copy(searching = false) }
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
        _ui.update { it.copy(stage = Stage.OPTIONS, optionsLoading = true, options = emptyList(), selected = null, error = null, sharing = false, sharedQuote = null) }
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

    fun select(slug: String) = _ui.update { it.copy(selected = slug, sharing = false, sharedQuote = null) }

    /** Prices the chosen car as a shared trip, so the rider sees exactly what they save. */
    fun setSharing(share: Boolean) {
        val state = _ui.value
        if (!share) {
            _ui.update { it.copy(sharing = false) }
            return
        }
        val pickup = state.pickup?.point ?: return
        val dropoff = state.dropoff?.point ?: return
        val slug = state.selected ?: return
        act {
            val quote = api.createQuote(slug, pickup, dropoff, shared = true)
            _ui.update { it.copy(sharing = true, sharedQuote = quote) }
        }
    }

    fun book() {
        val state = _ui.value
        val quote = state.sharedQuote?.takeIf { state.sharing } ?: state.options.firstOrNull { it.category.slug == state.selected }?.quote ?: return
        if (state.busy) return
        if (state.selected == SEND_CATEGORY) {
            _ui.update { it.copy(stage = Stage.SEND_DETAILS, error = null) }
            return
        }
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

    /** Books a delivery on the Send quote the sender chose. */
    fun sendPackage(details: DeliveryRequest) {
        val state = _ui.value
        val quote = state.options.firstOrNull { it.category.slug == SEND_CATEGORY }?.quote ?: return
        act {
            try {
                showRide(send.book(details.copy(quoteId = quote.id, liabilityAcknowledged = state.needsAcknowledgement && details.liabilityAcknowledged)))
            } catch (e: ProblemException) {
                if (e.code == "LIABILITY_ACK_REQUIRED") _ui.update { it.copy(needsAcknowledgement = true) }
                if (e.code == "QUOTE_EXPIRED" || e.code == "QUOTE_NOT_FOUND") loadOptions()
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
        _ui.update { it.copy(stage = Stage.HOME, ride = null, driverPhoto = null, options = emptyList(), dropoff = null, error = null, delivery = null, needsAcknowledgement = false) }
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
        // Send is the one category without seats, and the only one riders can book a package on.
        val categories = api.listVehicleCategories().filter { it.capacity > 0 || it.slug == SEND_CATEGORY }.associateBy { it.slug }
        return api.createQuotes(pickup, dropoff).mapNotNull { priced -> categories[priced.category]?.let { RideOption(it, priced.quote) } }
    }

    private fun showRide(ride: Ride) {
        _ui.update { it.copy(stage = Stage.TRIP, ride = ride, error = null) }
        loadPhoto(ride)
        viewModelScope.launch { runCatching { send.getDelivery(ride.id) }.getOrNull()?.let { d -> _ui.update { it.copy(delivery = d) } } }
        if (visible) startPolling()
    }

    /** Applies a live update at once, instead of waiting for the next poll. */
    private suspend fun onLive(event: RealtimeEvent) {
        val ride = _ui.value.ride ?: return
        when {
            event.type == "driver.location" && event.rideId == ride.id && event.lat != null && event.lng != null ->
                _ui.update { it.copy(ride = it.ride?.copy(driverLocation = Coordinates(event.lat, event.lng))) }
            (event.type == "ride.status" && event.rideId == ride.id) || event.type == "resync" || event.type == "send.updated" -> refreshRide(ride.id)
        }
    }

    private suspend fun refreshRide(id: String) {
        val fresh = runCatching { api.getRide(id) }.getOrNull() ?: return
        if (_ui.value.ride?.id != id) return
        _ui.update { it.copy(ride = fresh) }
        loadPhoto(fresh)
        if (_ui.value.delivery != null) runCatching { send.getDelivery(id) }.getOrNull()?.let { d -> _ui.update { it.copy(delivery = d) } }
    }

    private fun startPolling() {
        pollJob?.cancel()
        if (_ui.value.ride?.let { RideStatus.isActive(it.status) } != true) return
        pollJob = viewModelScope.launch {
            while (true) {
                // Live updates do the work while the socket is up, so polling slows to a safety net.
                delay(if (realtime.connected.value) SLOW_POLL_MS else POLL_MS)
                val id = _ui.value.ride?.id ?: return@launch
                try {
                    val ride = api.getRide(id)
                    _ui.update { it.copy(ride = ride, reconnecting = false) }
                    loadPhoto(ride)
                    if (_ui.value.delivery != null) send.getDelivery(id)?.let { d -> _ui.update { it.copy(delivery = d) } }
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
        const val SEND_CATEGORY = "send"
        const val MIN_QUERY = 3
        const val SEARCH_DEBOUNCE_MS = 400L
        const val POLL_MS = 3_000L
        const val SLOW_POLL_MS = 15_000L
    }
}
