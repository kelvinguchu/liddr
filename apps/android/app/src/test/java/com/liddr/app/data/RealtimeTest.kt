package com.liddr.app.data

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

private class Saved(var value: Tokens?) : TokenStore {
    override fun load() = value
    override fun save(tokens: Tokens) { value = tokens }
    override fun clear() { value = null }
}

class RealtimeTest {
    private val server = MockWebServer()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Before fun start() = server.start()

    @After fun stop() {
        scope.cancel()
        server.shutdown()
    }

    private fun pushing(frame: String) = MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            webSocket.send(frame)
        }
    })

    private fun realtime(store: Saved): Realtime {
        val transport = Transport(server.url("/").toString())
        val session = SessionManager(transport, store) { 0L }.also { it.restore() }
        return Realtime(server.url("/").toString(), session)
    }

    @Test fun eventsArriveWithTheSessionToken() = runBlocking {
        server.enqueue(pushing("""{"type":"ride.status","ride_id":"r1","status":"accepted"}"""))
        val live = realtime(Saved(Tokens("a1", Long.MAX_VALUE, "r1", listOf("rider"))))
        val seen = async(start = CoroutineStart.UNDISPATCHED) { live.events.first { it.type == "ride.status" } }
        live.start(scope)
        val event = withTimeout(5_000) { seen.await() }
        assertEquals(RealtimeEvent(type = "ride.status", rideId = "r1", status = "accepted"), event)
        assertEquals("Bearer a1", server.takeRequest(1, TimeUnit.SECONDS)!!.getHeader("Authorization"))
        live.stop()
    }

    @Test fun refusedTokenIsRefreshedThenTheSocketOpens() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401))
        server.enqueue(MockResponse().setBody("""{"access_token":"a2","access_token_expires_in":900,"refresh_token":"r2","refresh_token_expires_in":1,"user_id":"u","roles":["rider"]}"""))
        server.enqueue(pushing("""{"type":"offer.created","offer_id":"o1","ride_id":"r1"}"""))
        val store = Saved(Tokens("a1", Long.MAX_VALUE, "r1", listOf("driver")))
        val live = realtime(store)
        val seen = async(start = CoroutineStart.UNDISPATCHED) { live.events.first { it.type == "offer.created" } }
        live.start(scope)
        val event = withTimeout(5_000) { seen.await() }
        assertEquals("o1", event.offerId)
        server.takeRequest()
        assertEquals("/v1/auth/refresh", server.takeRequest().path)
        assertEquals("Bearer a2", server.takeRequest().getHeader("Authorization"))
        assertEquals("r2", store.value?.refreshToken)
        live.stop()
    }

    @Test fun connectingAsksScreensToCatchUp() = runBlocking {
        server.enqueue(pushing("""{"type":"ride.status","ride_id":"r1","status":"arrived"}"""))
        val live = realtime(Saved(Tokens("a1", Long.MAX_VALUE, "r1", listOf("rider"))))
        val seen = async(start = CoroutineStart.UNDISPATCHED) { live.events.first { it.type == "resync" } }
        live.start(scope)
        withTimeout(5_000) { seen.await() }
        live.stop()
    }
}
