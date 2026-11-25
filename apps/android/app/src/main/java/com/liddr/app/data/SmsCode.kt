package com.liddr.app.data

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.core.os.BundleCompat
import com.google.android.gms.auth.api.phone.SmsRetriever
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Status
import java.security.MessageDigest
import kotlinx.coroutines.CompletableDeferred

/**
 * Reads the sign-in code from Liddr's SMS with Google Play services' SMS Retriever,
 * which needs no SMS permission: Android hands over only a message that ends with
 * this app's hash, and only for five minutes after [awaitCode] starts.
 */
class SmsCodeReader(context: Context) {
    private val app = context.applicationContext

    /** The hash the API appends to the SMS, or null when the signature can't be read. */
    val appHash: String? by lazy { signature()?.let { appHash(app.packageName, it) } }

    /** Waits for the sign-in SMS and returns its code, or null if none arrives in time. */
    suspend fun awaitCode(): String? {
        val result = CompletableDeferred<String?>()
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val extras = intent.extras ?: return
                val status = BundleCompat.getParcelable(extras, SmsRetriever.EXTRA_STATUS, Status::class.java)
                val message = extras.getString(SmsRetriever.EXTRA_SMS_MESSAGE).takeIf { status?.statusCode == CommonStatusCodes.SUCCESS }
                result.complete(message?.let(::codeFromSms))
            }
        }
        ContextCompat.registerReceiver(
            app,
            receiver,
            IntentFilter(SmsRetriever.SMS_RETRIEVED_ACTION),
            SmsRetriever.SEND_PERMISSION,
            null,
            ContextCompat.RECEIVER_EXPORTED,
        )
        try {
            SmsRetriever.getClient(app).startSmsRetriever().addOnFailureListener { result.complete(null) }
            return result.await()
        } finally {
            app.unregisterReceiver(receiver)
        }
    }

    @Suppress("DEPRECATION") // GET_SIGNATURES is the only way on Android 8 and older.
    private fun signature(): String? = try {
        val signers = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo?.apkContentsSigners
        } else {
            app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_SIGNATURES).signatures
        }
        signers?.firstOrNull()?.toCharsString()
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }
}

private val smsCode = Regex("""code is: (\d{6})""")

/** The six-digit code in Liddr's sign-in SMS. */
internal fun codeFromSms(message: String): String? = smsCode.find(message)?.groupValues?.get(1)

/**
 * The SMS Retriever hash: the first 9 bytes of SHA-256 over "package signature",
 * in base64, cut to 11 characters, as Google's AppSignatureHelper computes it.
 */
internal fun appHash(packageName: String, signature: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest("$packageName $signature".toByteArray(Charsets.UTF_8))
    return base64(digest.copyOf(HASH_BYTES)).take(HASH_LENGTH)
}

// android.util.Base64 is missing from unit tests and java.util.Base64 needs Android 8.
private fun base64(bytes: ByteArray): String = buildString {
    for (i in bytes.indices step 3) {
        val chunk = (bytes[i].toInt() and 0xFF shl 16) or
            (bytes.getOrElse(i + 1) { 0 }.toInt() and 0xFF shl 8) or
            (bytes.getOrElse(i + 2) { 0 }.toInt() and 0xFF)
        for (shift in intArrayOf(18, 12, 6, 0)) append(BASE64[chunk shr shift and 0x3F])
    }
}

private const val HASH_BYTES = 9
private const val HASH_LENGTH = 11
private const val BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
