package com.liddr.app.ui.driver

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.liddr.app.data.Delivery
import com.liddr.app.data.DriverApi
import com.liddr.app.data.DriverProfile
import com.liddr.app.data.Earnings
import com.liddr.app.data.LiddrApi
import com.liddr.app.data.Offer
import com.liddr.app.data.OfflineException
import com.liddr.app.data.ProblemException
import com.liddr.app.data.Realtime
import com.liddr.app.data.RealtimeEvent
import com.liddr.app.data.Ride
import com.liddr.app.data.RideStatus
import com.liddr.app.data.SendApi
import com.liddr.app.data.SharedRide
import com.liddr.app.data.Subscription
import com.liddr.app.data.VehicleCategory
import com.liddr.app.data.VerificationState
import com.liddr.app.service.DriverLocationControl
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class DriverScreen { LOADING, LOAD_FAILED, CATEGORY, VERIFICATION, SUBSCRIPTION, HOME, TRIP, RATE }

data class DriverUiState(
    val screen: DriverScreen = DriverScreen.LOADING,
    val profile: DriverProfile? = null,
    val categories: List<VehicleCategory> = emptyList(),
    val verification: VerificationState? = null,
    val uploading: String? = null,
    val subscription: Subscription? = null,
    val paying: Boolean = false,
    val offers: List<Offer> = emptyList(),
    val earnings: Earnings? = null,
    val ride: Ride? = null,
    val ratingRideId: String? = null,
    val delivery: Delivery? = null,
    val shared: SharedRide? = null,
    val busy: Boolean = false,
    val error: String? = null,
    val reconnecting: Boolean = false,
)

class DriverViewModel(
    private val api: DriverApi,
    private val shared: LiddrApi,
    private val send: SendApi,
    private val location: DriverLocationControl,
    private val realtime: Realtime,
) : ViewModel() {
    private val _ui = MutableStateFlow(DriverUiState())
    val ui: StateFlow<DriverUiState> = _ui.asStateFlow()

    private var loop: Job? = null
    private var ticks = 0

    init {
        viewModelScope.launch { refresh(showFailure = true) }
        viewModelScope.launch { realtime.events.collect(::onLive) }
    }

    /** Offers expire in seconds, so they are fetched the moment the API announces one. */
    private suspend fun onLive(event: RealtimeEvent) {
        try {
            when (event.type) {
                "offer.created" -> if (_ui.value.screen == DriverScreen.HOME) _ui.update { it.copy(offers = api.listOffers()) }
                "offer.closed" -> _ui.update { state -> state.copy(offers = state.offers.filterNot { it.id == event.offerId }) }
                "ride.status", "send.updated" -> if (_ui.value.screen == DriverScreen.TRIP && event.rideId == _ui.value.ride?.id) pollTrip()
                "resync" -> tick()
            }
        } catch (e: ProblemException) {
            _ui.update { it.copy(reconnecting = true) }
        } catch (e: OfflineException) {
            _ui.update { it.copy(reconnecting = true) }
        }
    }

    fun retry() {
        _ui.update { it.copy(screen = DriverScreen.LOADING) }
        viewModelScope.launch { refresh(showFailure = true) }
    }

    /** Only polls while the driver can see the app. */
    fun setVisible(visible: Boolean) {
        loop?.cancel()
        if (!visible) return
        loop = viewModelScope.launch {
            while (true) {
                delay(POLL_MS)
                tick()
            }
        }
    }

    fun chooseCategory(slug: String) = act {
        _ui.update { it.copy(profile = api.setCategory(slug)) }
        refresh()
    }

    fun startApplication(plate: String, fullName: String) = act {
        api.startApplication(plate, fullName)
        refresh()
    }

    fun upload(type: String, contentType: String, bytes: ByteArray, expiresOn: String?) {
        _ui.update { it.copy(uploading = type, error = null) }
        viewModelScope.launch {
            try {
                api.uploadDocument(type, contentType, bytes, expiresOn)
                _ui.update { it.copy(verification = api.getVerification()) }
            } catch (e: ProblemException) {
                _ui.update { it.copy(error = e.message) }
            } catch (e: OfflineException) {
                _ui.update { it.copy(error = e.message) }
            } finally {
                _ui.update { it.copy(uploading = null) }
            }
        }
    }

    fun reportError(message: String) = _ui.update { it.copy(error = message) }

    fun pay() = act {
        api.paySubscription()
        _ui.update { it.copy(paying = true) }
    }

    fun goOnline() = act {
        api.goOnline()
        location.start()
        _ui.update { state -> state.copy(profile = state.profile?.copy(isOnline = true)) }
    }

    fun goOffline() = act {
        api.goOffline()
        location.stop()
        _ui.update { state -> state.copy(profile = state.profile?.copy(isOnline = false), offers = emptyList()) }
    }

    fun accept(offer: Offer) = act {
        try {
            api.acceptOffer(offer.id)
            showTrip(api.getRide(offer.rideId))
        } catch (e: ProblemException) {
            if (e.code == "OFFER_CLOSED" || e.code == "OFFER_NOT_FOUND") _ui.update { it.copy(offers = it.offers - offer) }
            throw e
        }
    }

    fun reject(offer: Offer) = act {
        _ui.update { it.copy(offers = it.offers - offer) }
        api.rejectOffer(offer.id)
    }

    /** Moves the trip to its next stage. The API checks the driver is really there. */
    fun advance(action: String) = withRide { id -> applyRide(api.advance(id, action)) }

    fun complete(paymentMode: String) = withRide { id -> applyRide(api.complete(id, paymentMode)) }

    fun cancel(reason: String) = withRide { id -> applyRide(api.cancel(id, reason)) }

    /** Attaches the collection or delivery photo. The API will not let a delivery move on without it. */
    fun uploadProof(kind: String, bytes: ByteArray) = withRide { id ->
        send.uploadProof(id, kind, bytes)
        _ui.update { it.copy(delivery = send.getDelivery(id)) }
    }

    /** Moves one passenger of a shared trip along. The API checks the driver is at their stop. */
    fun memberStep(memberId: String, step: String) = withRide { id ->
        api.memberStep(id, memberId, step)
        _ui.update { it.copy(shared = api.getSharedRide(id)) }
        applyRide(api.getRide(id))
    }

    fun leaveTrip() {
        _ui.update { it.copy(ride = null, error = null) }
        viewModelScope.launch { refresh() }
    }

    fun submitRating(score: Int, tags: List<String>, comment: String) =
        finishRating { id -> shared.rateRide(id, score, tags, comment.trim().takeIf(String::isNotEmpty)) }

    fun skipRating() = finishRating { id -> shared.skipRating(id) }

    private fun finishRating(block: suspend (String) -> Unit) {
        val id = _ui.value.ratingRideId ?: return
        act {
            try {
                block(id)
            } catch (e: ProblemException) {
                if (e.code != "RATING_NOT_AVAILABLE" && e.code != "ALREADY_DONE") throw e
            }
            _ui.update { it.copy(ratingRideId = null, ride = null, delivery = null, shared = null) }
            refresh()
        }
    }

    private fun withRide(block: suspend (String) -> Unit) {
        val id = _ui.value.ride?.id ?: return
        act { block(id) }
    }

    private fun applyRide(ride: Ride) {
        _ui.update {
            if (ride.status == RideStatus.COMPLETED) {
                it.copy(ride = ride, ratingRideId = ride.id, screen = DriverScreen.RATE)
            } else {
                it.copy(ride = ride)
            }
        }
    }

    private suspend fun showTrip(ride: Ride) {
        _ui.update { it.copy(screen = DriverScreen.TRIP, ride = ride, offers = emptyList()) }
        val delivery = runCatching { send.getDelivery(ride.id) }.getOrNull()
        val shared = runCatching { api.getSharedRide(ride.id) }.getOrNull()
        _ui.update { it.copy(delivery = delivery, shared = shared) }
    }

    /** Works out which step the driver is on. Each step must be finished before the next. */
    private suspend fun refresh(showFailure: Boolean = false) {
        try {
            val active = api.findActiveRide()
            if (active != null) {
                showTrip(active)
                return
            }
            // An offer accepted while this check was in flight must not be undone by its
            // now out-of-date answer, which would send the driver back to the home screen.
            if (_ui.value.ride?.let { RideStatus.isActive(it.status) } == true) return
            val profile = api.getProfile()
            if (profile == null) {
                val categories = shared.listVehicleCategories()
                _ui.update { it.copy(screen = DriverScreen.CATEGORY, categories = categories, profile = null) }
                return
            }
            _ui.update { it.copy(profile = profile) }
            when {
                profile.verificationStatus != "approved" -> {
                    val verification = api.getVerification()
                    _ui.update { it.copy(screen = DriverScreen.VERIFICATION, verification = verification) }
                }
                profile.subscriptionStatus !in setOf("active", "grace") -> {
                    val subscription = api.getSubscription()
                    _ui.update { it.copy(screen = DriverScreen.SUBSCRIPTION, subscription = subscription) }
                }
                else -> showHome(profile)
            }
        } catch (e: ProblemException) {
            if (showFailure) _ui.update { it.copy(screen = DriverScreen.LOAD_FAILED, error = e.message) }
        } catch (e: OfflineException) {
            if (showFailure) _ui.update { it.copy(screen = DriverScreen.LOAD_FAILED, error = e.message) }
        }
    }

    private suspend fun showHome(profile: DriverProfile) {
        if (profile.isOnline) location.start() else location.stop()
        val earnings = runCatching { api.getEarnings() }.getOrNull()
        val owed = runCatching { shared.listPendingRatings() }.getOrNull()?.firstOrNull { it.raterRole == "driver" }
        _ui.update {
            when {
                owed != null -> it.copy(screen = DriverScreen.RATE, ratingRideId = owed.rideId, earnings = earnings)
                else -> it.copy(screen = DriverScreen.HOME, earnings = earnings ?: it.earnings, paying = false)
            }
        }
    }

    private suspend fun tick() {
        ticks++
        try {
            when (_ui.value.screen) {
                DriverScreen.VERIFICATION -> if (ticks % SLOW_EVERY == 0) refresh()
                DriverScreen.SUBSCRIPTION -> checkPayment()
                DriverScreen.HOME -> pollHome()
                DriverScreen.TRIP -> pollTrip()
                else -> Unit
            }
            _ui.update { it.copy(reconnecting = false) }
        } catch (e: OfflineException) {
            _ui.update { it.copy(reconnecting = true) }
        } catch (e: ProblemException) {
            _ui.update { it.copy(reconnecting = true) }
        }
    }

    private suspend fun checkPayment() {
        if (!_ui.value.paying) return
        val latest = api.latestPayment()?.status
        if (latest == "success") {
            refresh()
        } else if (latest in setOf("failed", "cancelled", "timeout")) {
            _ui.update { it.copy(paying = false, error = "The M-Pesa payment didn't go through. Please try again.") }
        }
    }

    private suspend fun pollHome() {
        val profile = _ui.value.profile ?: return
        if (ticks % SLOW_EVERY == 0) {
            refresh() // Picks up a lapsed subscription or a suspension.
            return
        }
        if (profile.isOnline) {
            val offers = api.listOffers()
            _ui.update { it.copy(offers = offers) }
        }
    }

    private suspend fun pollTrip() {
        val id = _ui.value.ride?.id ?: return
        val ride = api.getRide(id)
        if (_ui.value.ride?.id == id) applyRide(ride)
        if (_ui.value.delivery != null) _ui.update { it.copy(delivery = send.getDelivery(id)) }
        if (_ui.value.shared != null) _ui.update { it.copy(shared = api.getSharedRide(id)) }
    }

    private fun act(block: suspend () -> Unit) {
        if (_ui.value.busy) return
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
        const val POLL_MS = 3_000L
        const val SLOW_EVERY = 10
    }
}
