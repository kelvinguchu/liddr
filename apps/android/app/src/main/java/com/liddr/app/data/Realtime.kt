package com.liddr.app.data

import kotlin.coroutines.resume
import kotlin.math.min
import kotlin.random.Random
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/** A live update. The API's types are ride.status, offer.created, offer.closed, driver.location and resync. */
@Serializable
data class RealtimeEvent(
    val type: String,
    @SerialName("ride_id") val rideId: String? = null,
    @SerialName("offer_id") val offerId: String? = null,
    val status: String? = null,
    val lat: Double? = null,
    val lng: Double? = null,
)

/**
 * Keeps one socket open while the app is on screen. Screens still poll slowly
 * as a fallback, and fetch fresh state on resync, since a socket can miss
 * updates while it reconnects.
 */
class Realtime(
    baseUrl: String,
    private val session: SessionManager,
    private val client: OkHttpClient = OkHttpClient(),
) {
    private val url = baseUrl.trimEnd('/').replaceFirst("http", "ws") + "/v1/realtime"
    // The latest event is replayed, so a screen that starts listening just after the
    // socket connects still gets the catch-up signal. Handlers only refetch, so a
    // repeated event is harmless.
    private val _events = MutableSharedFlow<RealtimeEvent>(replay = 1, extraBufferCapacity = 64)
    val events: SharedFlow<RealtimeEvent> = _events
    private val _connected = MutableStateFlow(false)
    val connected: StateFlow<Boolean> = _connected

    private var job: Job? = null

    fun start(scope: CoroutineScope) {
        if (job?.isActive == true) return
        job = scope.launch { run() }
    }

    fun stop() {
        job?.cancel()
        job = null
        _connected.value = false
    }

    private suspend fun run() {
        var failures = 0
        while (true) {
            val opened = try {
                // A refused token is refreshed and retried once, as for any request. Each
                // attempt has its own close signal: one shared with the refused attempt would
                // already be complete, and the new socket would be dropped as soon as it opened.
                session.withAccess { token -> open(token) }
            } catch (e: ProblemException) {
                if (e.status == 401 && session.state.value is SessionState.SignedOut) return
                null
            } catch (e: OfflineException) {
                null
            }
            if (opened != null) {
                val (socket, closed) = opened
                failures = 0
                _connected.value = true
                _events.tryEmit(RealtimeEvent(type = "resync"))
                try {
                    closed.await()
                } finally {
                    socket.cancel()
                    _connected.value = false
                }
            }
            failures++
            // Spread reconnects so phones do not all return at once after an outage.
            val backoff = min(MAX_BACKOFF_MS, BASE_BACKOFF_MS shl min(failures, 5))
            delay(backoff / 2 + Random.nextLong(backoff / 2))
        }
    }

    /** Opens the socket and returns it, with a signal that completes when it closes. */
    private suspend fun open(token: String): Pair<WebSocket, CompletableDeferred<Unit>> = suspendCancellableCoroutine { waiter ->
        val closed = CompletableDeferred<Unit>()
        val request = Request.Builder().url(url).header("Authorization", "Bearer $token").build()
        val socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (waiter.isActive) waiter.resume(webSocket to closed)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                runCatching { apiJson.decodeFromString<RealtimeEvent>(text) }.getOrNull()?.let { _events.tryEmit(it) }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                closed.complete(Unit)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                closed.complete(Unit)
                if (!waiter.isActive) return
                val failure = if (response?.code == 401) ProblemException(401, "UNAUTHENTICATED", "Please sign in again.") else OfflineException(t)
                waiter.resumeWith(Result.failure(failure))
            }
        })
        waiter.invokeOnCancellation { socket.cancel() }
    }

    private companion object {
        const val BASE_BACKOFF_MS = 1_000L
        const val MAX_BACKOFF_MS = 30_000L
    }
}
