package com.liddr.app.data

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable data class Coordinates(val lat: Double, val lng: Double)

@Serializable data class VehicleCategory(val slug: String, val label: String, val capacity: Int)

@Serializable internal data class CategoryList(val data: List<VehicleCategory>)

@Serializable
internal data class QuoteRequest(
    @SerialName("vehicle_category") val category: String,
    val pickup: Coordinates,
    val dropoff: Coordinates,
    @SerialName("product_type") val productType: String? = null,
)

@Serializable
data class Quote(
    val id: String,
    @SerialName("fare_kes") val fareKes: Int,
    @SerialName("surge_bps") val surgeBps: Int,
    @SerialName("distance_m") val distanceM: Int,
    @SerialName("duration_s") val durationS: Int,
    val polyline: String = "",
    @SerialName("solo_fare_kes") val soloFareKes: Int? = null,
)

@Serializable internal data class QuoteAllRequest(val pickup: Coordinates, val dropoff: Coordinates)

@Serializable
data class CategoryQuote(@SerialName("vehicle_category") val category: String, val quote: Quote)

@Serializable internal data class CategoryQuoteList(val data: List<CategoryQuote>)

@Serializable internal data class BookRequest(@SerialName("quote_id") val quoteId: String)

@Serializable internal data class CancelRequest(val reason: String)

@Serializable
data class DriverCard(
    val name: String? = null,
    @SerialName("plate_number") val plateNumber: String? = null,
    @SerialName("photo_url") val photoUrl: String? = null,
    @SerialName("vehicle_category") val vehicleCategory: String,
    @SerialName("completed_rides") val completedRides: Int,
    val rating: Double? = null,
)

@Serializable data class RiderCard(val name: String? = null, val rating: Double? = null)

@Serializable
data class Ride(
    val id: String,
    val status: String,
    val pickup: Coordinates,
    val dropoff: Coordinates,
    @SerialName("fare_kes") val fareKes: Int,
    @SerialName("driver_location") val driverLocation: Coordinates? = null,
    val driver: DriverCard? = null,
    val rider: RiderCard? = null,
)

@Serializable internal data class HistoryItem(val id: String, val status: String)

@Serializable internal data class RideHistory(val data: List<HistoryItem>)

@Serializable
data class PendingRating(@SerialName("ride_id") val rideId: String, @SerialName("rater_role") val raterRole: String)

@Serializable internal data class PendingRatingList(val data: List<PendingRating>)

@Serializable
internal data class RatingSubmission(
    val score: Int,
    @SerialName("reason_tags") val reasonTags: List<String>,
    val comment: String? = null,
)

object RideStatus {
    const val SEARCHING = "searching"
    const val ACCEPTED = "accepted"
    const val DRIVER_ARRIVING = "driver_arriving"
    const val ARRIVED = "arrived"
    const val IN_PROGRESS = "in_progress"
    const val COMPLETED = "completed"
    const val CANCELLED = "cancelled"
    const val NO_DRIVERS = "no_drivers"

    fun isActive(status: String) = status in setOf(SEARCHING, ACCEPTED, DRIVER_ARRIVING, ARRIVED, IN_PROGRESS)

    /** A rider cannot abandon a trip once it has started. */
    fun canCancel(status: String) = isActive(status) && status != IN_PROGRESS
}

/** Straight-line distance in metres. */
fun distanceMetres(a: Coordinates, b: Coordinates): Double {
    val earth = 6_371_000.0
    val dLat = Math.toRadians(b.lat - a.lat)
    val dLng = Math.toRadians(b.lng - a.lng)
    val h = sin(dLat / 2) * sin(dLat / 2) +
        cos(Math.toRadians(a.lat)) * cos(Math.toRadians(b.lat)) * sin(dLng / 2) * sin(dLng / 2)
    return 2 * earth * atan2(sqrt(h), sqrt(1 - h))
}

/** Decodes Google's encoded polyline format into points. */
fun decodePolyline(encoded: String): List<Coordinates> {
    val points = mutableListOf<Coordinates>()
    var index = 0
    var lat = 0
    var lng = 0
    fun next(): Int? {
        var result = 0
        var shift = 0
        while (index < encoded.length) {
            val b = encoded[index++].code - 63
            result = result or ((b and 0x1f) shl shift)
            shift += 5
            if (b < 0x20) return if (result and 1 != 0) (result shr 1).inv() else result shr 1
        }
        return null
    }
    while (index < encoded.length) {
        lat += next() ?: break
        lng += next() ?: break
        points += Coordinates(lat / 1e5, lng / 1e5)
    }
    return points
}

@Serializable
data class SharedMember(
    val id: String,
    val status: String,
    @SerialName("is_self") val isSelf: Boolean,
    @SerialName("fare_kes") val fareKes: Int? = null,
)

@Serializable
data class SharedStop(@SerialName("member_id") val memberId: String, val kind: String, val point: Coordinates)

@Serializable
data class SharedRide(
    @SerialName("ride_id") val rideId: String,
    val status: String,
    val members: List<SharedMember>,
    val stops: List<SharedStop>,
    @SerialName("earnings_kes") val earningsKes: Int? = null,
)

/** Categories that can be shared: cars with room for a second passenger. */
fun canShare(category: VehicleCategory) = category.capacity >= 2 && category.slug != "send"
