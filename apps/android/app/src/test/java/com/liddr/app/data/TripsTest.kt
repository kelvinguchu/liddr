package com.liddr.app.data

import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Runnable
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class Held : TokenStore {
    private var value: Tokens? = Tokens("a", Long.MAX_VALUE, "r", listOf("rider"))
    override fun load() = value
    override fun save(tokens: Tokens) { value = tokens }
    override fun clear() { value = null }
}

private const val RIDE =
    """{"id":"r1","status":"accepted","pickup":{"lat":-1.29,"lng":36.82},"dropoff":{"lat":-1.3,"lng":36.8},"fare_kes":350,"requested_at":"2026-11-09T09:00:00Z",
    "driver":{"name":"Asha Njeri","plate_number":"KMFB123A","photo_url":"https://s/x","vehicle_category":"motorbike","completed_rides":12,"rating":4.8}}"""

class TripsTest {
    private val server = MockWebServer()
    private lateinit var api: LiddrApi

    @Before fun start() {
        server.start()
        val transport = Transport(server.url("/").toString())
        api = LiddrApi(transport, SessionManager(transport, Held()) { 0L }.also { it.restore() })
    }

    @After fun stop() = server.shutdown()

    @Test fun rideCarriesTheDriverCard() = runBlocking {
        server.enqueue(MockResponse().setBody(RIDE))
        val ride = api.getRide("r1")
        assertEquals("Asha Njeri", ride.driver?.name)
        assertEquals("KMFB123A", ride.driver?.plateNumber)
        assertEquals(4.8, ride.driver?.rating)
        assertEquals("Bearer a", server.takeRequest().getHeader("Authorization"))
    }

    @Test fun quoteSendsTheContractShape() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(201).setBody("""{"id":"q","fare_kes":200,"base_fare_kes":200,"discount_kes":0,"surge_bps":10000,"distance_m":5000,"duration_s":900,"polyline":"x","expires_at":"2026-11-09T09:05:00Z"}"""))
        assertEquals(200, api.createQuote("motorbike", Coordinates(-1.2, 36.8), Coordinates(-1.3, 36.9)).fareKes)
        val body = server.takeRequest().body.readUtf8()
        assertTrue(body, body.contains("\"vehicle_category\":\"motorbike\"") && body.contains("\"pickup\":{\"lat\":-1.2"))
    }

    @Test fun activeRideIsFoundAfterARestart() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"data":[{"id":"r1","status":"accepted","category":"motorbike","fare_kes":350,"requested_at":"2026-11-09T09:00:00Z"}]}"""))
        server.enqueue(MockResponse().setBody(RIDE))
        assertEquals("r1", api.findActiveRide()?.id)
        assertEquals("/v1/rides/history?as=rider&limit=1", server.takeRequest().path)
    }

    @Test fun finishedRideIsNotResumed() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"data":[{"id":"r1","status":"completed","category":"motorbike","fare_kes":350,"requested_at":"2026-11-09T09:00:00Z"}]}"""))
        assertNull(api.findActiveRide())
    }

    @Test fun ridersCannotCancelATripThatHasStarted() {
        assertTrue(RideStatus.canCancel(RideStatus.ARRIVED))
        assertFalse(RideStatus.canCancel(RideStatus.IN_PROGRESS))
        assertFalse(RideStatus.canCancel(RideStatus.COMPLETED))
    }

    @Test fun responsesAreReadOffTheCallersThread() = runBlocking {
        val used = AtomicInteger()
        val io = object : CoroutineDispatcher() {
            override fun dispatch(context: CoroutineContext, block: Runnable) {
                used.incrementAndGet()
                Dispatchers.Default.dispatch(context, block)
            }
        }
        server.enqueue(MockResponse().setBody("{}"))
        server.enqueue(MockResponse().setBody("x"))
        val transport = Transport(server.url("/").toString(), io = io)
        transport.send("GET", "/a")
        val afterSend = used.get()
        transport.download(server.url("/b").toString())
        assertTrue(afterSend > 0 && used.get() > afterSend)
    }

    @Test fun ratingSendsTheContractShape() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(204))
        api.rateRide("r1", 3, listOf("late"), "Slow pickup")
        val request = server.takeRequest()
        val body = request.body.readUtf8()
        assertEquals("/v1/rides/r1/rate", request.path)
        assertTrue(body, body.contains("\"score\":3") && body.contains("\"reason_tags\":[\"late\"]") && body.contains("\"comment\":\"Slow pickup\""))
    }

    @Test fun skippingUsesItsOwnRoute() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(204))
        api.skipRating("r1")
        assertEquals("/v1/rides/r1/rate/skip", server.takeRequest().path)
    }

    @Test fun pendingRatingsAreRead() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"data":[{"ride_id":"r1","rater_role":"rider","due_at":"2026-11-10T09:00:00Z"}]}"""))
        assertEquals(PendingRating("r1", "rider"), api.listPendingRatings().single())
        assertEquals("/v1/ratings/pending", server.takeRequest().path)
    }

    private fun drivers(): DriverApi {
        val transport = Transport(server.url("/").toString())
        return DriverApi(transport, SessionManager(transport, Held()) { 0L }.also { it.restore() })
    }

    @Test fun driverWithoutAProfileIsNotAnError() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404).setBody("""{"code":"DRIVER_PROFILE_MISSING","message":"m","request_id":"r"}"""))
        assertNull(drivers().getProfile())
    }

    @Test fun documentGoesToStorageThenIsRecorded() = runBlocking {
        val signed = server.url("/bucket/key").toString()
        server.enqueue(MockResponse().setResponseCode(201).setBody("""{"upload_id":"u1","upload_url":"$signed","headers":{"X-Goog-Content-Length-Range":"0,10"},"expires_at":"2026-11-09T10:00:00Z"}"""))
        server.enqueue(MockResponse().setResponseCode(200))
        server.enqueue(MockResponse().setResponseCode(201).setBody("{}"))
        drivers().uploadDocument("drivers_licence", "image/jpeg", byteArrayOf(1, 2, 3), "2027-11-09")
        val prepare = server.takeRequest().body.readUtf8()
        assertTrue(prepare, prepare.contains("\"document_type\":\"drivers_licence\"") && prepare.contains("\"size_bytes\":3"))
        val put = server.takeRequest()
        assertEquals("PUT", put.method)
        assertEquals("0,10", put.getHeader("X-Goog-Content-Length-Range"))
        assertNull("storage must not receive the session token", put.getHeader("Authorization"))
        assertEquals(3L, put.bodySize)
        val submit = server.takeRequest().body.readUtf8()
        assertTrue(submit, submit.contains("\"upload_id\":\"u1\"") && submit.contains("\"expires_on\":\"2027-11-09\""))
    }

    @Test fun applicationSendsConsent() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(201).setBody("{}"))
        drivers().startApplication("KMFB 123A", "Asha Njeri")
        val body = server.takeRequest().body.readUtf8()
        assertTrue(body, body.contains("\"photo_consent\":true") && body.contains("\"full_name\":\"Asha Njeri\""))
    }

    @Test fun completingATripSendsHowItWasPaid() = runBlocking {
        server.enqueue(MockResponse().setBody(RIDE))
        drivers().complete("r1", "mpesa_direct")
        val request = server.takeRequest()
        assertEquals("/v1/rides/r1/complete", request.path)
        assertEquals("{\"payment_mode\":\"mpesa_direct\"}", request.body.readUtf8())
    }

    @Test fun distanceIsSensible() {
        val metres = distanceMetres(Coordinates(-1.2921, 36.8219), Coordinates(-1.3000, 36.8000))
        assertTrue("$metres", metres in 2400.0..2700.0)
    }
}
