package com.liddr.app.ui.driver

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class PreparedFile(val contentType: String, val bytes: ByteArray)

private const val MAX_EDGE_PX = 2048
private const val JPEG_QUALITY = 85

/**
 * Reads a chosen file. Photos are re-encoded smaller, which saves the driver's
 * data and removes the location the camera stored inside the file.
 */
suspend fun readDocument(context: Context, uri: Uri): PreparedFile? = withContext(Dispatchers.IO) {
    val resolver = context.contentResolver
    val type = resolver.getType(uri)
    if (type == "application/pdf") {
        return@withContext resolver.openInputStream(uri)?.use { PreparedFile(type, it.readBytes()) }
    }
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    var sample = 1
    while (bounds.outWidth / sample > MAX_EDGE_PX || bounds.outHeight / sample > MAX_EDGE_PX) sample *= 2
    val bitmap = resolver.openInputStream(uri)?.use {
        BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
    } ?: return@withContext null
    val out = ByteArrayOutputStream()
    bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
    bitmap.recycle()
    PreparedFile("image/jpeg", out.toByteArray())
}
