package com.liddr.app.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

@Serializable
data class Delivery(
    @SerialName("ride_id") val rideId: String,
    @SerialName("sender_name") val senderName: String,
    @SerialName("recipient_name") val recipientName: String,
    @SerialName("recipient_phone") val recipientPhone: String? = null,
    @SerialName("item_description") val itemDescription: String,
    @SerialName("item_size") val itemSize: String,
    val payer: String,
    @SerialName("payment_timing") val paymentTiming: String,
    @SerialName("special_instructions") val specialInstructions: String? = null,
    val status: String,
    @SerialName("pickup_proof_at") val pickupProofAt: String? = null,
    @SerialName("dropoff_proof_at") val dropoffProofAt: String? = null,
    @SerialName("confirmed_at") val confirmedAt: String? = null,
)

@Serializable
data class DeliveryRequest(
    @SerialName("quote_id") val quoteId: String,
    @SerialName("sender_name") val senderName: String,
    @SerialName("recipient_name") val recipientName: String,
    @SerialName("recipient_phone") val recipientPhone: String,
    @SerialName("item_description") val itemDescription: String,
    @SerialName("item_size") val itemSize: String,
    val payer: String,
    @SerialName("payment_timing") val paymentTiming: String,
    @SerialName("special_instructions") val specialInstructions: String? = null,
    @SerialName("liability_acknowledged") val liabilityAcknowledged: Boolean = false,
)

@Serializable
data class AppNotification(
    val id: String,
    @SerialName("event_type") val eventType: String,
    @SerialName("ride_id") val rideId: String? = null,
    val status: String? = null,
)

@Serializable internal data class NotificationList(val data: List<AppNotification>)

@Serializable internal data class ProofRequest(
    @SerialName("proof_kind") val kind: String,
    @SerialName("content_type") val contentType: String,
    @SerialName("size_bytes") val sizeBytes: Long,
)

@Serializable internal data class ProofSubmission(@SerialName("upload_id") val uploadId: String)

/** Package delivery for senders, recipients and drivers. */
class SendApi(private val transport: Transport, private val session: SessionManager) {
    suspend fun book(request: DeliveryRequest): Ride = session.withAccess { token ->
        apiJson.decodeFromString(transport.send("POST", "/v1/send/requests", bearer = token, json = apiJson.encodeToString(request)))
    }

    /** Returns null for an ordinary ride, which has no delivery. */
    suspend fun getDelivery(rideId: String): Delivery? = try {
        session.withAccess { token -> apiJson.decodeFromString<Delivery>(transport.send("GET", "/v1/send/rides/$rideId", bearer = token)) }
    } catch (e: ProblemException) {
        if (e.status != 404) throw e
        null
    }

    suspend fun confirmReceipt(rideId: String) {
        session.withAccess { token -> transport.send("POST", "/v1/send/rides/$rideId/recipient-confirm", bearer = token) }
    }

    /** Photographs go straight to private storage, and are then attached to the delivery. */
    suspend fun uploadProof(rideId: String, kind: String, bytes: ByteArray) {
        val ticket = session.withAccess { token ->
            apiJson.decodeFromString<UploadTicket>(
                transport.send("POST", "/v1/send/rides/$rideId/proof-uploads", bearer = token, json = apiJson.encodeToString(ProofRequest(kind, "image/jpeg", bytes.size.toLong()))),
            )
        }
        transport.upload(ticket.uploadUrl, ticket.headers, "image/jpeg", bytes)
        session.withAccess { token ->
            transport.send("POST", "/v1/send/rides/$rideId/$kind-proof", bearer = token, json = apiJson.encodeToString(ProofSubmission(ticket.uploadId)))
        }
    }

    suspend fun listNotifications(): List<AppNotification> = session.withAccess { token ->
        apiJson.decodeFromString<NotificationList>(transport.send("GET", "/v1/notifications", bearer = token)).data
    }

    suspend fun acknowledge(notificationId: String) {
        session.withAccess { token -> transport.send("POST", "/v1/notifications/$notificationId/ack", bearer = token) }
    }
}
