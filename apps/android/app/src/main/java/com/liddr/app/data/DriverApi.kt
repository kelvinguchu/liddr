package com.liddr.app.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

@Serializable
data class DriverProfile(
    @SerialName("vehicle_category") val vehicleCategory: String,
    @SerialName("verification_status") val verificationStatus: String,
    @SerialName("subscription_status") val subscriptionStatus: String,
    @SerialName("is_online") val isOnline: Boolean,
)

@Serializable
data class VerificationDocument(
    val status: String,
    @SerialName("rejection_reason") val rejectionReason: String? = null,
)

@Serializable
data class Requirement(
    @SerialName("document_type") val documentType: String,
    val label: String,
    val required: Boolean,
    @SerialName("requires_expiry") val requiresExpiry: Boolean,
    val document: VerificationDocument? = null,
)

@Serializable
data class Application(val status: String, @SerialName("decision_reason") val decisionReason: String? = null)

@Serializable
data class VerificationState(
    @SerialName("driver_status") val driverStatus: String,
    val application: Application? = null,
    val requirements: List<Requirement> = emptyList(),
)

@Serializable
data class Subscription(
    val status: String,
    @SerialName("amount_kes") val amountKes: Int,
    val reference: String,
    @SerialName("paybill_shortcode") val paybillShortcode: String,
)

@Serializable data class SubscriptionPayment(val status: String)

@Serializable
data class Offer(
    val id: String,
    @SerialName("ride_id") val rideId: String,
    @SerialName("distance_to_pickup_m") val distanceToPickupM: Int,
    @SerialName("fare_kes") val fareKes: Int,
    @SerialName("rider_rating") val riderRating: Double? = null,
)

@Serializable data class EarningsPeriod(val trips: Int, @SerialName("total_kes") val totalKes: Int)

@Serializable
data class Earnings(val today: EarningsPeriod, @SerialName("this_week") val thisWeek: EarningsPeriod)

@Serializable
internal data class UploadTicket(
    @SerialName("upload_id") val uploadId: String,
    @SerialName("upload_url") val uploadUrl: String,
    val headers: Map<String, String> = emptyMap(),
)

@Serializable internal data class OfferList(val data: List<Offer>)

@Serializable internal data class PaymentList(val data: List<SubscriptionPayment>)

@Serializable internal data class CategoryChoice(@SerialName("vehicle_category") val category: String)

@Serializable
internal data class ApplicationRequest(
    @SerialName("plate_number") val plate: String,
    @SerialName("full_name") val fullName: String,
    @SerialName("photo_consent") val photoConsent: Boolean,
)

@Serializable
internal data class PrepareUpload(
    @SerialName("document_type") val documentType: String,
    @SerialName("content_type") val contentType: String,
    @SerialName("size_bytes") val sizeBytes: Long,
)

@Serializable
internal data class SubmitDocument(
    @SerialName("upload_id") val uploadId: String,
    @SerialName("expires_on") val expiresOn: String? = null,
)

@Serializable internal data class CompleteTrip(@SerialName("payment_mode") val paymentMode: String)

@Serializable internal data class ReasonBody(val reason: String)

/** The API routes only drivers use. */
class DriverApi(private val transport: Transport, private val session: SessionManager) {
    /** Returns null until the driver has chosen a vehicle category. */
    suspend fun getProfile(): DriverProfile? = try {
        get("/v1/drivers/me")
    } catch (e: ProblemException) {
        if (e.code != "DRIVER_PROFILE_MISSING") throw e
        null
    }

    suspend fun setCategory(slug: String): DriverProfile = call("PUT", "/v1/drivers/me", apiJson.encodeToString(CategoryChoice(slug)))

    suspend fun getVerification(): VerificationState = get("/v1/verification/status")

    suspend fun startApplication(plate: String, fullName: String) {
        send("POST", "/v1/verification/applications", apiJson.encodeToString(ApplicationRequest(plate, fullName, photoConsent = true)))
    }

    /** Asks for a signed link, sends the file straight to storage, then records it. */
    suspend fun uploadDocument(type: String, contentType: String, bytes: ByteArray, expiresOn: String?) {
        val ticket: UploadTicket = call("POST", "/v1/verification/uploads", apiJson.encodeToString(PrepareUpload(type, contentType, bytes.size.toLong())))
        transport.upload(ticket.uploadUrl, ticket.headers, contentType, bytes)
        send("POST", "/v1/verification/documents", apiJson.encodeToString(SubmitDocument(ticket.uploadId, expiresOn)))
    }

    suspend fun getSubscription(): Subscription = get("/v1/subscriptions/me")

    suspend fun latestPayment(): SubscriptionPayment? = get<PaymentList>("/v1/subscriptions/me/payments").data.firstOrNull()

    suspend fun paySubscription() {
        send("POST", "/v1/subscriptions/pay", "{}")
    }

    suspend fun goOnline() {
        send("POST", "/v1/drivers/me/online")
    }

    suspend fun goOffline() {
        send("POST", "/v1/drivers/me/offline")
    }

    suspend fun updateLocation(point: Coordinates) {
        send("POST", "/v1/drivers/me/location", apiJson.encodeToString(point))
    }

    suspend fun listOffers(): List<Offer> = get<OfferList>("/v1/drivers/me/offers").data

    suspend fun acceptOffer(id: String) {
        send("POST", "/v1/offers/$id/accept")
    }

    suspend fun rejectOffer(id: String) {
        send("POST", "/v1/offers/$id/reject")
    }

    /** Returns null for a solo ride, which has no shared group. */
    suspend fun getSharedRide(rideId: String): SharedRide? = try {
        get("/v1/rides/$rideId/shared")
    } catch (e: ProblemException) {
        if (e.status != 404) throw e
        null
    }

    /** Records one passenger's progress: arrive-pickup, picked-up, dropped-off or no-show. */
    suspend fun memberStep(rideId: String, memberId: String, step: String) {
        send("POST", "/v1/rides/$rideId/shared/members/$memberId/$step")
    }

    suspend fun getEarnings(): Earnings = get("/v1/drivers/me/earnings")

    suspend fun getRide(id: String): Ride = get("/v1/rides/$id")

    suspend fun advance(rideId: String, action: String): Ride = call("POST", "/v1/rides/$rideId/$action", null)

    suspend fun complete(rideId: String, paymentMode: String): Ride =
        call("POST", "/v1/rides/$rideId/complete", apiJson.encodeToString(CompleteTrip(paymentMode)))

    suspend fun cancel(rideId: String, reason: String): Ride =
        call("POST", "/v1/rides/$rideId/cancel", apiJson.encodeToString(ReasonBody(reason)))

    /** The trip this driver is still on, so the app can return to it after a restart. */
    suspend fun findActiveRide(): Ride? {
        val latest = get<RideHistory>("/v1/rides/history?as=driver&limit=1").data.firstOrNull() ?: return null
        return if (RideStatus.isActive(latest.status)) getRide(latest.id) else null
    }

    private suspend inline fun <reified T> get(path: String): T =
        session.withAccess { token -> apiJson.decodeFromString<T>(transport.send("GET", path, bearer = token)) }

    private suspend inline fun <reified T> call(method: String, path: String, json: String?): T =
        session.withAccess { token -> apiJson.decodeFromString<T>(transport.send(method, path, bearer = token, json = json)) }

    private suspend fun send(method: String, path: String, json: String? = null) {
        session.withAccess { token -> transport.send(method, path, bearer = token, json = json) }
    }
}
