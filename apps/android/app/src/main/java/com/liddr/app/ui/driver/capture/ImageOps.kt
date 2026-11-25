package com.liddr.app.ui.driver.capture

import com.liddr.app.ui.driver.uprightCard
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import java.io.ByteArrayOutputStream
import kotlin.math.max

// Turns what the camera took into the file Liddr uploads: upright, no larger
// than staff need to read it, and re-encoded so nothing the camera wrote into
// the file (place, time, phone model) leaves the phone.

/** A photo waiting for review. [quad] is the document's outline in unit space. */
class Shot(val bitmap: Bitmap, val quad: Quad)

private const val MAX_UPLOAD_EDGE = 2048
private const val JPEG_QUALITY = 85
// Enough detail to straighten a page to the upload size without holding a full sensor frame.
private const val MAX_SOURCE_EDGE = 3200
private const val DETECT_EDGE = 320
private const val LEVELS_EDGE = 200
private const val FALLBACK_INSET = 0.08f

/** Decodes the camera's JPEG and turns it [rotation] degrees clockwise so it stands upright. */
internal fun decodeUpright(jpeg: ByteArray, rotation: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, bounds)
    var sample = 1
    while (max(bounds.outWidth, bounds.outHeight) / sample > MAX_SOURCE_EDGE) sample *= 2
    val decoded = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
    if (rotation % 360 == 0) return decoded
    val turned = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, Matrix().apply { postRotate(rotation.toFloat()) }, true)
    if (turned !== decoded) decoded.recycle()
    return turned
}

/**
 * Pairs a photo with the outline to offer in review: the document found in the
 * photo itself, else where the viewfinder last saw it, else a plain inset.
 */
internal fun shotOf(bitmap: Bitmap, kind: CaptureKind, lastSeen: Quad?): Shot {
    if (kind != CaptureKind.DOCUMENT) return Shot(bitmap, Quad.inset(0f))
    val frame = grayOf(bitmap)
    val found = detectDocument(frame)?.quad?.toUnit(frame)
    return Shot(bitmap, found ?: lastSeen ?: Quad.inset(FALLBACK_INSET))
}

/** An outline in a frame's pixels as unit space. Pixel centres sit half a pixel in. */
internal fun Quad.toUnit(frame: GrayFrame) = map { Pt(((it.x + 0.5f) / frame.width).coerceIn(0f, 1f), ((it.y + 0.5f) / frame.height).coerceIn(0f, 1f)) }

private fun grayOf(bitmap: Bitmap): GrayFrame {
    val size = fitWithin(bitmap.width, bitmap.height, DETECT_EDGE)
    val small = Bitmap.createScaledBitmap(bitmap, size.width, size.height, true)
    val frame = GrayFrame(lumaOf(small), size.width, size.height)
    if (small !== bitmap) small.recycle()
    return frame
}

private fun lumaOf(bitmap: Bitmap): ByteArray {
    val argb = IntArray(bitmap.width * bitmap.height)
    bitmap.getPixels(argb, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
    return ByteArray(argb.size) {
        val c = argb[it]
        ((((c shr 16) and 0xFF) * 77 + ((c shr 8) and 0xFF) * 150 + (c and 0xFF) * 29) shr 8).toByte()
    }
}

/** The upload for a vehicle photo or selfie: the photo as taken, at upload size. */
internal fun photoJpeg(bitmap: Bitmap): ByteArray? = try {
    val size = fitWithin(bitmap.width, bitmap.height, MAX_UPLOAD_EDGE)
    val scaled = Bitmap.createScaledBitmap(bitmap, size.width, size.height, true)
    val bytes = jpegOf(scaled)
    if (scaled !== bitmap) scaled.recycle()
    bytes
} catch (_: OutOfMemoryError) {
    // A phone short of memory: the caller asks the driver to try again.
    null
}

/**
 * The upload for a document: the area inside [quad] pulled square, as if
 * photographed from directly above, with faded ink and grey paper stretched
 * back towards black and white.
 */
internal fun documentJpeg(bitmap: Bitmap, quad: Quad, documentType: String): ByteArray? = try {
    val source = quad.scaled(bitmap.width.toFloat(), bitmap.height.toFloat())
    val size = outputSize(source, MAX_UPLOAD_EDGE)
    // A small pass first to measure the page's tones, then the real one with them applied.
    val probe = fitWithin(size.width, size.height, LEVELS_EDGE)
    val small = straighten(bitmap, source, probe, null)
    val histogram = IntArray(256)
    for (value in lumaOf(small)) histogram[value.toInt() and 0xFF]++
    small.recycle()
    // An ID or licence photographed upright comes out portrait; it is saved landscape.
    val page = uprightCard(straighten(bitmap, source, size, levelsFor(histogram)), documentType)
    val bytes = jpegOf(page)
    page.recycle()
    bytes
} catch (_: OutOfMemoryError) {
    null
}

private fun straighten(bitmap: Bitmap, source: Quad, size: PixelSize, levels: Levels?): Bitmap {
    val w = size.width.toFloat()
    val h = size.height.toFloat()
    val from = source.corners.flatMap { listOf(it.x, it.y) }.toFloatArray()
    val to = floatArrayOf(0f, 0f, w, 0f, w, h, 0f, h)
    val warp = Matrix().apply { setPolyToPoly(from, 0, to, 0, 4) }
    val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    if (levels != null) {
        val g = levels.gain
        val o = levels.offset
        paint.colorFilter = ColorMatrixColorFilter(ColorMatrix(floatArrayOf(g, 0f, 0f, 0f, o, 0f, g, 0f, 0f, o, 0f, 0f, g, 0f, o, 0f, 0f, 0f, 1f, 0f)))
    }
    val out = Bitmap.createBitmap(size.width, size.height, Bitmap.Config.ARGB_8888)
    Canvas(out).drawBitmap(bitmap, warp, paint)
    return out
}

private fun jpegOf(bitmap: Bitmap): ByteArray {
    val out = ByteArrayOutputStream()
    bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
    return out.toByteArray()
}
