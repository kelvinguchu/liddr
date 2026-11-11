package com.liddr.app.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class SessionBody(
    @SerialName("access_token") val accessToken: String,
    @SerialName("access_token_expires_in") val accessExpiresIn: Int,
    @SerialName("refresh_token") val refreshToken: String,
    val roles: List<String> = emptyList(),
)

@Serializable
private data class RefreshBody(@SerialName("refresh_token") val refreshToken: String)

sealed interface SessionState {
    data object Loading : SessionState

    /** [generation] changes on every sign-in and sign-out, so screens never outlive a person. */
    data class SignedOut(val generation: Int) : SessionState
    data class SignedIn(val roles: List<String>, val generation: Int) : SessionState
}

/**
 * Owns the device's tokens. The API revokes the whole session if a refresh
 * token is ever used twice, so refreshes run strictly one at a time, and a
 * caller that finds the token already replaced simply uses the new one.
 */
class SessionManager(
    private val transport: Transport,
    private val store: TokenStore,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val refreshLock = Mutex()
    private val _state = MutableStateFlow<SessionState>(SessionState.Loading)
    val state: StateFlow<SessionState> = _state.asStateFlow()

    @Volatile private var tokens: Tokens? = null
    private var generation = 0

    /** Reads saved tokens. Call once at launch, away from the main thread. */
    fun restore() {
        if (_state.value != SessionState.Loading) return // The activity is being recreated.
        tokens = store.load()
        _state.value = tokens?.let { SessionState.SignedIn(it.roles, ++generation) } ?: SessionState.SignedOut(++generation)
    }

    fun signedIn(body: SessionBody) {
        val fresh = body.toTokens(body.roles)
        store.save(fresh)
        tokens = fresh
        _state.value = SessionState.SignedIn(fresh.roles, ++generation)
    }

    /** Runs [call] with a valid access token, refreshing once if the API rejects it. */
    suspend fun <T> withAccess(call: suspend (String) -> T): T {
        val current = tokens ?: throw signedOutError()
        val access = if (now() >= current.accessExpiresAt - EARLY_MS) refreshAfter(current.accessToken) else current.accessToken
        return try {
            call(access)
        } catch (e: ProblemException) {
            if (e.status != 401) throw e
            call(refreshAfter(access))
        }
    }

    /** Ends the session on this device even if the API cannot be told. */
    suspend fun signOut() {
        val current = refreshLock.withLock {
            val held = tokens
            clearLocal()
            held
        } ?: return
        runCatching {
            transport.send("POST", "/v1/auth/logout", json = apiJson.encodeToString(RefreshBody.serializer(), RefreshBody(current.refreshToken)))
        }
    }

    /** Forgets the session after the API has already ended it. */
    suspend fun forget() = refreshLock.withLock { clearLocal() }

    private suspend fun refreshAfter(stale: String): String = refreshLock.withLock {
        val current = tokens ?: throw signedOutError()
        if (current.accessToken != stale) return@withLock current.accessToken
        val text = try {
            transport.send("POST", "/v1/auth/refresh", json = apiJson.encodeToString(RefreshBody.serializer(), RefreshBody(current.refreshToken)))
        } catch (e: ProblemException) {
            // A server fault says nothing about the token, so only a refusal ends the session.
            if (e.status in 400..499 && e.status != 429) clearLocal()
            throw e
        }
        val body = apiJson.decodeFromString<SessionBody>(text)
        val fresh = body.toTokens(body.roles.ifEmpty { current.roles })
        store.save(fresh)
        tokens = fresh
        fresh.accessToken
    }

    private fun clearLocal() {
        store.clear()
        tokens = null
        _state.value = SessionState.SignedOut(++generation)
    }

    private fun SessionBody.toTokens(roles: List<String>) =
        Tokens(accessToken, now() + accessExpiresIn * 1000L, refreshToken, roles)

    private fun signedOutError() = ProblemException(401, "SIGNED_OUT", "Please sign in again.")

    private companion object {
        /** Refresh this early, so a token cannot expire on the way to the API. */
        const val EARLY_MS = 30_000L
    }
}

