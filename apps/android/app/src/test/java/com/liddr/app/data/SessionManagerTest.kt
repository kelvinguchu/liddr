package com.liddr.app.data

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private class MemoryStore(var saved: Tokens? = null) : TokenStore {
    override fun load() = saved
    override fun save(tokens: Tokens) { saved = tokens }
    override fun clear() { saved = null }
}

private fun session(n: Int, expiresIn: Int = 900) =
    """{"access_token":"access-$n","access_token_expires_in":$expiresIn,"refresh_token":"refresh-$n","refresh_token_expires_in":2592000,"user_id":"u","roles":["rider"]}"""

private fun problem(status: Int, code: String) =
    MockResponse().setResponseCode(status).setBody("""{"code":"$code","message":"$code message","request_id":"r"}""")

class SessionManagerTest {
    private val server = MockWebServer()
    private val refreshes = AtomicInteger()
    private var refreshResponse: () -> MockResponse = { MockResponse().setBody(session(refreshes.get() + 1)) }
    private var validToken = "access-2"
    private var clock = 0L

    @Before fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.path) {
                "/v1/auth/refresh" -> { refreshes.incrementAndGet(); Thread.sleep(60); refreshResponse() }
                "/v1/auth/logout" -> MockResponse().setResponseCode(204)
                else ->
                    if (request.getHeader("Authorization") == "Bearer $validToken") MockResponse().setBody("""{"id":"u"}""")
                    else problem(401, "UNAUTHENTICATED")
            }
        }
        server.start()
    }

    @After fun stop() = server.shutdown()

    private fun manager(store: MemoryStore): Pair<SessionManager, Transport> {
        val transport = Transport(server.url("/").toString())
        return SessionManager(transport, store) { clock }.also { it.restore() } to transport
    }

    private fun held(access: String = "access-1", expiresAt: Long = 900_000) =
        MemoryStore(Tokens(access, expiresAt, "refresh-1", listOf("rider")))

    private suspend fun SessionManager.me(t: Transport) = withAccess { t.send("GET", "/v1/me", bearer = it) }

    @Test fun manyRejectedCallsShareOneRefresh() = runBlocking {
        val store = held()
        val (m, t) = manager(store)
        val results = withContext(Dispatchers.IO) { List(12) { async { m.me(t) } }.awaitAll() }
        assertEquals(12, results.size)
        assertEquals(1, refreshes.get())
        assertEquals("access-2", store.saved?.accessToken)
        assertEquals("refresh-2", store.saved?.refreshToken)
    }

    @Test fun tokenAboutToExpireIsRefreshedBeforeUse() = runBlocking {
        val (m, t) = manager(held(expiresAt = 20_000))
        m.me(t)
        assertEquals(1, refreshes.get())
        assertEquals(1, server.requestCount - 1)
    }

    @Test fun healthyTokenIsNotRefreshed() = runBlocking {
        validToken = "access-1"
        val (m, t) = manager(held())
        m.me(t)
        assertEquals(0, refreshes.get())
    }

    @Test fun refusedRefreshSignsOut() {
        refreshResponse = { problem(401, "INVALID_REFRESH") }
        val store = held()
        val (m, t) = manager(store)
        assertThrows(ProblemException::class.java) { runBlocking { m.me(t) } }
        assertNull(store.saved)
        assertTrue(m.state.value is SessionState.SignedOut)
    }

    @Test fun serverFaultDuringRefreshKeepsTheSession() {
        refreshResponse = { problem(503, "UNAVAILABLE") }
        val store = held()
        val (m, t) = manager(store)
        assertThrows(ProblemException::class.java) { runBlocking { m.me(t) } }
        assertEquals("refresh-1", store.saved?.refreshToken)
        assertTrue(m.state.value is SessionState.SignedIn)
    }

    @Test fun offlineDuringRefreshKeepsTheSession() {
        val store = held()
        val (m, t) = manager(store)
        server.shutdown()
        assertThrows(OfflineException::class.java) { runBlocking { m.me(t) } }
        assertEquals("refresh-1", store.saved?.refreshToken)
    }

    @Test fun signOutClearsTheDeviceEvenIfTheApiIsGone() = runBlocking {
        val store = held()
        val (m, _) = manager(store)
        server.shutdown()
        m.signOut()
        assertNull(store.saved)
        assertTrue(m.state.value is SessionState.SignedOut)
    }

    @Test fun eachPersonGetsANewGeneration() = runBlocking {
        val (m, _) = manager(held())
        val first = (m.state.value as SessionState.SignedIn).generation
        m.signOut()
        val out = (m.state.value as SessionState.SignedOut).generation
        m.signedIn(apiJson.decodeFromString(session(9)))
        val second = (m.state.value as SessionState.SignedIn).generation
        assertTrue(first < out && out < second)
    }

    @Test fun recreatingTheActivityDoesNotRestartTheSession() {
        val (m, _) = manager(held())
        val before = m.state.value
        m.restore()
        assertEquals(before, m.state.value)
    }

    @Test fun nothingSavedMeansSignedOut() {
        val (m, _) = manager(MemoryStore())
        assertTrue(m.state.value is SessionState.SignedOut)
    }

    @Test fun apiMessageAndRetryAfterReachTheCaller() {
        val transportServer = MockWebServer().apply {
            enqueue(problem(429, "RATE_LIMITED").setHeader("Retry-After", "42"))
            start()
        }
        val t = Transport(transportServer.url("/").toString())
        val e = assertThrows(ProblemException::class.java) { runBlocking { t.send("POST", "/x", json = "{}") } }
        assertEquals("RATE_LIMITED message", e.message)
        assertEquals(42, e.retryAfterSeconds)
        transportServer.shutdown()
    }
}
