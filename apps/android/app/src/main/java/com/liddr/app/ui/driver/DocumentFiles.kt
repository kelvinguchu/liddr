package com.liddr.app.ui.driver

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import com.liddr.app.ui.driver.capture.quarterTurnsLeft
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class PreparedFile(val contentType: String, val bytes: ByteArray)

private const val MAX_EDGE_PX = 2048
private const val JPEG_QUALITY = 85

/**
 * Reads a chosen file. Photos are re-encoded smaller, which saves the driver's
 * data and removes the location the camera stored inside the file.
 */
suspend fun readDocument(context: Context, uri: Uri, documentType: String = ""): PreparedFile? = withContext(Dispatchers.IO) {
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
    val upright = uprightCard(bitmap, documentType)
    val out = ByteArrayOutputStream()
    upright.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
    upright.recycle()
    PreparedFile("image/jpeg", out.toByteArray())
}

private const val PREVIEW_EDGE_PX = 1600

/**
 * Turns a file the driver sent into a picture for the drawer: a photo scaled
 * down, or a PDF's first page. Kept in memory only. A PDF has to pass through a
 * file for the platform renderer, so it is written to the cache and deleted
 * straight after. Returns null when the file can't be read.
 */
suspend fun previewOf(context: Context, bytes: ByteArray, documentType: String): Bitmap? = withContext(Dispatchers.IO) {
    // Files sent before cards were turned on the phone can still arrive sideways.
    (if (isPdf(bytes)) firstPage(context, bytes) else scaledPhoto(bytes))?.let { uprightCard(it, documentType) }
}

private fun scaledPhoto(bytes: ByteArray): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    var sample = 1
    while (bounds.outWidth / sample > PREVIEW_EDGE_PX || bounds.outHeight / sample > PREVIEW_EDGE_PX) sample *= 2
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
}

private fun firstPage(context: Context, bytes: ByteArray): Bitmap? {
    val file = File.createTempFile("preview", ".pdf", context.cacheDir)
    return try {
        file.writeBytes(bytes)
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { pdf ->
                if (pdf.pageCount == 0) return null
                pdf.openPage(0).use { page ->
                    val scale = PREVIEW_EDGE_PX.toFloat() / maxOf(page.width, page.height)
                    val bitmap = Bitmap.createBitmap((page.width * scale).toInt(), (page.height * scale).toInt(), Bitmap.Config.ARGB_8888)
                    // A PDF page has no background of its own, so it is drawn on white paper.
                    bitmap.eraseColor(android.graphics.Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    bitmap
                }
            }
        }
    } catch (_: IOException) {
        null
    } catch (_: SecurityException) {
        // A password-protected PDF.
        null
    } finally {
        // Deleting a cache file can only fail if it is already gone.
        file.delete()
    }
}

/**
 * The picture for [documentType] the right way up: a landscape card that came
 * out portrait is turned a quarter to the left. Returns [bitmap] itself when
 * nothing changes, and otherwise recycles it.
 */
internal fun uprightCard(bitmap: Bitmap, documentType: String): Bitmap {
    if (quarterTurnsLeft(documentType, bitmap.width, bitmap.height) == 0) return bitmap
    val turned = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(-QUARTER_TURN) }, true)
    if (turned !== bitmap) bitmap.recycle()
    return turned
}

private const val QUARTER_TURN = 90f
