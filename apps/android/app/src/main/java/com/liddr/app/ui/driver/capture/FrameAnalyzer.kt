package com.liddr.app.ui.driver.capture

import android.graphics.Bitmap
import android.graphics.PointF
import android.media.FaceDetector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import kotlin.math.max

private const val ANALYSIS_EDGE = 320
private const val DOCUMENT_HOLD_MS = 900L
private const val FACE_HOLD_MS = 1200L
private const val MAX_FACES = 3

/**
 * Reads each viewfinder frame on the camera's analysis thread and publishes
 * what it saw. Everything stays on the phone. Each frame is closed before the
 * next arrives, and the loop ends when the camera session unbinds it.
 */
internal class FrameAnalyzer(
    private val kind: CaptureKind,
    private val nowMs: () -> Long,
    private val publish: (LiveReading) -> Unit,
) : ImageAnalysis.Analyzer {
    private val steadiness = QuadSteadiness()
    private val hold = HoldTimer(if (kind == CaptureKind.SELFIE) FACE_HOLD_MS else DOCUMENT_HOLD_MS)
    private var faces: FaceFinder? = null

    override fun analyze(image: ImageProxy) {
        try {
            val plane = image.planes[0]
            val buffer = plane.buffer
            val step = max(1, (max(image.width, image.height) + ANALYSIS_EDGE - 1) / ANALYSIS_EDGE)
            val frame = uprightGray({ buffer.get(it) }, plane.rowStride, plane.pixelStride, image.width, image.height, step, image.imageInfo.rotationDegrees)
            publish(if (kind == CaptureKind.SELFIE) readFace(frame) else readDocument(frame))
        } finally {
            image.close()
        }
    }

    private fun readDocument(frame: GrayFrame): LiveReading {
        val quad = detectDocument(frame)?.quad?.toUnit(frame)
        val hint = documentHint(quad, frame.mean())
        // Both run every frame: steadiness has to see each outline to know when one moves.
        val steady = steadiness.isSteady(quad)
        return LiveReading(hint, quad, hold.update(hint.ready && steady, nowMs()))
    }

    private fun readFace(frame: GrayFrame): LiveReading {
        val finder = faces?.takeIf { it.fits(frame) } ?: FaceFinder(frame.width, frame.height).also { faces = it }
        val hint = faceHint(finder.find(frame), frame.width, frame.height)
        return LiveReading(hint, null, hold.update(hint.ready, nowMs()))
    }
}

/**
 * The platform's own face finder. It reports where the eyes are and how far
 * apart, which is enough to say whether a face is centred and close enough. It
 * cannot tell a person from a picture of one, and nothing here claims it can.
 */
private class FaceFinder(private val frameWidth: Int, private val frameHeight: Int) {
    // The platform detector only accepts even widths.
    private val width = frameWidth and 1.inv()
    private val detector = FaceDetector(width, frameHeight, MAX_FACES)
    private val bitmap = Bitmap.createBitmap(width, frameHeight, Bitmap.Config.RGB_565)
    private val colours = IntArray(width * frameHeight)
    private val found = arrayOfNulls<FaceDetector.Face>(MAX_FACES)
    private val eyes = PointF()

    fun fits(frame: GrayFrame) = frame.width == frameWidth && frame.height == frameHeight

    fun find(frame: GrayFrame): List<FaceReading> {
        for (y in 0 until frameHeight) for (x in 0 until width) {
            val grey = frame.pixels[y * frameWidth + x].toInt() and 0xFF
            colours[y * width + x] = (0xFF shl 24) or (grey shl 16) or (grey shl 8) or grey
        }
        bitmap.setPixels(colours, 0, width, 0, 0, width, frameHeight)
        val count = detector.findFaces(bitmap, found)
        return (0 until count).mapNotNull { index ->
            val face = found[index] ?: return@mapNotNull null
            face.getMidPoint(eyes)
            FaceReading(eyes.x, eyes.y, face.eyesDistance(), face.confidence())
        }
    }
}
