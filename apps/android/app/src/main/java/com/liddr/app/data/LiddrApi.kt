package com.liddr.app.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

@Serializable data class Challenge(@SerialName("challenge_id") val challengeId: String)

@Serializable
data class Me(
    val id: String,
    val phone: String = "",
    val roles: List<String> = emptyList(),
    @SerialName("display_name") val displayName: String? = null,
)

@Serializable private data class PhoneCodeRequest(val phone: String, val role: String)

@Serializable private data class EmailCodeRequest(val email: String)

@Serializable
private data class CodeCheck(@SerialName("challenge_id") val challengeId: String, val code: String)

@Serializable private data class NameChange(@SerialName("display_name") val displayName: String)

/** The API routes the app uses, named as the contract names them. */
class LiddrApi(private val transport: Transport, private val session: SessionManager) {
    suspend fun requestOtp(phone: String, role: String): Challenge = decode(
        transport.send("POST", "/v1/auth/otp/request", json = apiJson.encodeToString(PhoneCodeRequest(phone, role))),
    )

    suspend fun verifyOtp(challengeId: String, code: String) = signIn("/v1/auth/otp/verify", challengeId, code)

    suspend fun requestEmailOtp(email: String): Challenge = decode(
        transport.send("POST", "/v1/auth/email/request", json = apiJson.encodeToString(EmailCodeRequest(email))),
    )

    suspend fun verifyEmailOtp(challengeId: String, code: String) = signIn("/v1/auth/email/verify", challengeId, code)

    suspend fun getMe(): Me = session.withAccess { token -> decode(transport.send("GET", "/v1/me", bearer = token)) }

    suspend fun updateMe(displayName: String): Me = session.withAccess { token ->
        decode(transport.send("PATCH", "/v1/me", bearer = token, json = apiJson.encodeToString(NameChange(displayName))))
    }

    /** The person's own data as JSON, ready to save. Needs a recent sign-in. */
    suspend fun exportMe(): String = session.withAccess { token -> transport.send("GET", "/v1/me/export", bearer = token) }

    /** Deletes the account. The API has ended the session by the time this returns. */
    suspend fun deleteMe() {
        session.withAccess { token -> transport.send("DELETE", "/v1/me", bearer = token) }
        session.forget()
    }

    suspend fun listVehicleCategories(): List<VehicleCategory> =
        decode<CategoryList>(transport.send("GET", "/v1/vehicle-categories")).data

    suspend fun createQuote(category: String, pickup: Coordinates, dropoff: Coordinates, shared: Boolean = false): Quote = session.withAccess { token ->
        val request = QuoteRequest(category, pickup, dropoff, productType = if (shared) "shared" else null)
        decode(transport.send("POST", "/v1/rides/quotes", bearer = token, json = apiJson.encodeToString(request)))
    }

    /** Prices the trip in every open category in one request, sharing routes between them. */
    suspend fun createQuotes(pickup: Coordinates, dropoff: Coordinates): List<CategoryQuote> = session.withAccess { token ->
        decode<CategoryQuoteList>(transport.send("POST", "/v1/rides/quotes/batch", bearer = token, json = apiJson.encodeToString(QuoteAllRequest(pickup, dropoff)))).data
    }

    /** Repeating this for the same quote returns the same ride, so a retry cannot double-book. */
    suspend fun bookRide(quoteId: String): Ride = session.withAccess { token ->
        decode(transport.send("POST", "/v1/rides", bearer = token, json = apiJson.encodeToString(BookRequest(quoteId))))
    }

    suspend fun getRide(id: String): Ride = session.withAccess { token ->
        decode(transport.send("GET", "/v1/rides/$id", bearer = token))
    }

    suspend fun cancelRide(id: String, reason: String): Ride = session.withAccess { token ->
        decode(transport.send("POST", "/v1/rides/$id/cancel", bearer = token, json = apiJson.encodeToString(CancelRequest(reason))))
    }

    /** The rider's trip still under way, so the app can return to it after a restart. */
    suspend fun findActiveRide(): Ride? {
        val latest = session.withAccess { token ->
            decode<RideHistory>(transport.send("GET", "/v1/rides/history?as=rider&limit=1", bearer = token))
        }.data.firstOrNull() ?: return null
        return if (RideStatus.isActive(latest.status)) getRide(latest.id) else null
    }

    suspend fun listPendingRatings(): List<PendingRating> = session.withAccess { token ->
        decode<PendingRatingList>(transport.send("GET", "/v1/ratings/pending", bearer = token)).data
    }

    suspend fun rateRide(rideId: String, score: Int, reasonTags: List<String>, comment: String?) {
        session.withAccess { token ->
            transport.send("POST", "/v1/rides/$rideId/rate", bearer = token, json = apiJson.encodeToString(RatingSubmission(score, reasonTags, comment)))
        }
    }

    suspend fun skipRating(rideId: String) {
        session.withAccess { token -> transport.send("POST", "/v1/rides/$rideId/rate/skip", bearer = token) }
    }

    /** Fetches a file from a signed link, which needs no session. */
    suspend fun download(url: String): ByteArray = transport.download(url)

    private suspend fun signIn(path: String, challengeId: String, code: String) {
        val body = transport.send("POST", path, json = apiJson.encodeToString(CodeCheck(challengeId, code)))
        session.signedIn(apiJson.decodeFromString<SessionBody>(body))
    }

    private inline fun <reified T> decode(text: String): T = apiJson.decodeFromString(text)
}
