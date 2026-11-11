package com.liddr.app.data

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/** The API refused a request. [message] is written by the API and safe to show. */
class ProblemException(
    val status: Int,
    val code: String,
    override val message: String,
    val retryAfterSeconds: Int? = null,
) : Exception(message)

/** The API could not be reached. Nothing is known about whether the request arrived. */
class OfflineException(cause: Throwable? = null) :
    Exception("We can't reach Liddr. Check your connection and try again.", cause)

@Serializable
private data class ProblemBody(
    val code: String,
    val message: String,
    @SerialName("request_id") val requestId: String = "",
)

val apiJson = Json { ignoreUnknownKeys = true }

/** Sends JSON to the API and turns every failure into one of the two exceptions above. */
class Transport(
    private val baseUrl: String,
    private val client: OkHttpClient = defaultClient(),
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    /** Runs away from the main thread, because reading a response body is network I/O. */
    suspend fun send(method: String, path: String, bearer: String? = null, json: String? = null): String = withContext(io) {
        val body = json?.toRequestBody(JSON_TYPE)
            ?: if (method == "GET") null else ByteArray(0).toRequestBody(JSON_TYPE)
        val request = Request.Builder()
            .url(baseUrl.trimEnd('/') + path)
            .method(method, body)
            .apply { bearer?.let { header("Authorization", "Bearer $it") } }
            .build()
        val response = try {
            client.newCall(request).await()
        } catch (e: IOException) {
            throw OfflineException(e)
        }
        response.use { read(it) }
    }

    /** Sends a file to a signed storage link, with exactly the headers the link was signed for. */
    suspend fun upload(url: String, headers: Map<String, String>, contentType: String, bytes: ByteArray) = withContext(io) {
        val request = Request.Builder().url(url).put(bytes.toRequestBody(contentType.toMediaType()))
            .apply { headers.forEach { (name, value) -> header(name, value) } }
            .build()
        val response = try {
            client.newCall(request).await()
        } catch (e: IOException) {
            throw OfflineException(e)
        }
        response.use { if (!it.isSuccessful) throw OfflineException() }
    }

    /** Fetches an absolute URL, such as a signed storage link. */
    suspend fun download(url: String): ByteArray = withContext(io) {
        val response = try {
            client.newCall(Request.Builder().url(url).build()).await()
        } catch (e: IOException) {
            throw OfflineException(e)
        }
        response.use {
            if (!it.isSuccessful) throw OfflineException()
            try {
                it.body?.bytes() ?: ByteArray(0)
            } catch (e: IOException) {
                throw OfflineException(e)
            }
        }
    }

    private fun read(response: Response): String {
        val text = try {
            response.body?.string().orEmpty()
        } catch (e: IOException) {
            throw OfflineException(e)
        }
        if (response.isSuccessful) return text
        val problem = runCatching { apiJson.decodeFromString<ProblemBody>(text) }.getOrNull()
        throw ProblemException(
            status = response.code,
            code = problem?.code ?: "UNEXPECTED_RESPONSE",
            message = problem?.message ?: "Something went wrong. Please try again.",
            retryAfterSeconds = response.header("Retry-After")?.toIntOrNull(),
        )
    }

    private companion object {
        val JSON_TYPE = "application/json".toMediaType()

        fun defaultClient() = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .callTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}

/** Awaits the call, and cancels it if the caller goes away. */
private suspend fun Call.await(): Response = suspendCancellableCoroutine { waiter: CancellableContinuation<Response> ->
    waiter.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) = waiter.resume(response)
        override fun onFailure(call: Call, e: IOException) = waiter.resumeWithException(e)
    })
}
