package com.liddr.app.ui.booking

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.liddr.app.data.AddressLookup
import com.liddr.app.data.HistoryItem
import com.liddr.app.data.LiddrApi
import com.liddr.app.data.OfflineException
import com.liddr.app.data.Place
import com.liddr.app.data.ProblemException
import com.liddr.app.data.VehicleCategory
import com.liddr.app.ui.kit.Notices
import java.text.ParseException
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class HomeUiState(
    val firstName: String? = null,
    val categories: List<VehicleCategory> = emptyList(),
    /** False until the vehicle types have been asked for once, so home can hold their place. */
    val categoriesLoaded: Boolean = false,
    /** Null while loading. */
    val recent: List<HistoryItem>? = null,
    /** The past trip being fetched to book again. */
    val reopening: String? = null,
    /** Destination names worked out on the phone, by trip id. */
    val names: Map<String, String> = emptyMap(),
    /** True when trips couldn't be loaded and there are none to show from before. */
    val tripsFailed: Boolean = false,
)

/** What home shows around the booking: the rider's name, the vehicle types and recent trips. */
class HomeViewModel(private val api: LiddrApi, private val addresses: AddressLookup, private val notices: Notices) : ViewModel() {
    private val _ui = MutableStateFlow(HomeUiState())
    val ui: StateFlow<HomeUiState> = _ui.asStateFlow()

    /** Called each time home appears, so a finished trip shows up straight away. */
    fun refresh() {
        viewModelScope.launch {
            val name = runCatching { api.getMe() }.getOrNull()?.displayName?.substringBefore(' ')?.takeIf(String::isNotBlank)
            _ui.update { it.copy(firstName = name ?: it.firstName) }
        }
        viewModelScope.launch {
            val offered = runCatching { api.listVehicleCategories() }.getOrNull()
            _ui.update { it.copy(categories = offered?.filter { c -> c.capacity > 0 || c.slug == "send" } ?: it.categories, categoriesLoaded = true) }
        }
        loadTrips()
    }

    /** Loads trips. A failure keeps the trips already shown, and says so only when there are none. */
    fun loadTrips() {
        _ui.update { it.copy(tripsFailed = false) }
        viewModelScope.launch {
            val trips = runCatching { api.listRecentTrips(limit = TRIPS_SHOWN) }.getOrNull()
            _ui.update { if (trips != null) it.copy(recent = trips) else it.copy(tripsFailed = it.recent == null) }
            trips?.let { nameDestinations(it) }
        }
    }

    /** Names each trip's destination on the phone, once, one at a time. */
    private suspend fun nameDestinations(trips: List<HistoryItem>) {
        for (trip in trips) {
            val point = trip.dropoff ?: continue
            if (trip.id in _ui.value.names) continue
            val name = addresses.describe(point)?.title ?: continue
            _ui.update { it.copy(names = it.names + (trip.id to name)) }
        }
    }

    /**
     * Fetches one past trip, names its destination on the phone, and hands it to
     * [onReady]. History lists never carry places, so this asks for one trip only.
     */
    fun again(item: HistoryItem, onReady: (Place, String) -> Unit) {
        item.dropoff?.let { point ->
            onReady(Place(_ui.value.names[item.id] ?: "Your last destination", "", point), item.category)
            return
        }
        if (_ui.value.reopening != null) return
        _ui.update { it.copy(reopening = item.id) }
        viewModelScope.launch {
            try {
                val ride = api.getRide(item.id)
                val place = addresses.describe(ride.dropoff) ?: Place("Your last destination", "", ride.dropoff)
                onReady(place, item.category)
            } catch (e: ProblemException) {
                notices.show(e.message ?: COULD_NOT_REOPEN, "Try again") { again(item, onReady) }
            } catch (e: OfflineException) {
                notices.show(e.message ?: COULD_NOT_REOPEN, "Try again") { again(item, onReady) }
            } finally {
                _ui.update { it.copy(reopening = null) }
            }
        }
    }
}

/** "Good morning", "Good afternoon" or "Good evening" for the hour of the day. */
internal fun greeting(hour: Int = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)) = when (hour) {
    in 5..11 -> "Good morning"
    in 12..16 -> "Good afternoon"
    else -> "Good evening"
}

/** "Fri 13 Nov, 17:16" in the phone's time zone, from the API's RFC 3339 time. */
internal fun tripDate(rfc3339: String, locale: Locale = Locale.getDefault()): String {
    // SimpleDateFormat reads milliseconds at most, so any fraction is dropped first.
    val trimmed = rfc3339.replace(Regex("""\.\d+"""), "")
    val parsed: Date = try {
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).parse(trimmed)
    } catch (e: ParseException) {
        null
    } ?: return ""
    return SimpleDateFormat("EEE d MMM, HH:mm", locale).format(parsed)
}

/** How many past trips the Trips tab lists; home shows the first few. */
private const val TRIPS_SHOWN = 30
private const val COULD_NOT_REOPEN = "We couldn't open that trip. Please try again."
