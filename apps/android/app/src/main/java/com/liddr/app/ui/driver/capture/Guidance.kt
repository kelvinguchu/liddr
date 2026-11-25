package com.liddr.app.ui.driver.capture

// What the camera tells the driver while they line up a shot, and when a shot
// is ready to take itself. Plain Kotlin, tested on the JVM.

/** A few words over the viewfinder, read in one glance. [ready] means the shot can be taken now. */
enum class Hint(val text: String, val ready: Boolean = false) {
    STARTING("Starting…"),
    FIND_DOCUMENT("Fit the whole document"),
    TOO_DARK("Too dark"),
    MOVE_CLOSER("Move closer"),
    HOLD_STEADY("Hold steady", ready = true),
    FRAME_VEHICLE("Fit the whole vehicle", ready = true),
    FIND_FACE("Face in the oval"),
    ONE_FACE("Only you, please"),
    CENTRE_FACE("Centre your face"),
    FACE_CLOSER("Move closer"),
    FACE_BACK("Move back"),
    FACE_READY("Hold still", ready = true),
}

/** What the camera sees right now. [quad] is in unit space; [progress] fills as a ready shot is held. */
data class LiveReading(val hint: Hint = Hint.STARTING, val quad: Quad? = null, val progress: Float = 0f)

private const val DARK_MEAN = 45
private const val SMALL_DOCUMENT = 0.14f

/** Guidance for a document, from its outline in unit space and the frame's mean brightness (0..255). */
fun documentHint(quad: Quad?, brightness: Int): Hint = when {
    quad == null && brightness < DARK_MEAN -> Hint.TOO_DARK
    quad == null -> Hint.FIND_DOCUMENT
    quad.area() < SMALL_DOCUMENT -> Hint.MOVE_CLOSER
    else -> Hint.HOLD_STEADY
}

/** A face as the platform detector reports it, in pixels of the analysed frame. */
data class FaceReading(val eyesX: Float, val eyesY: Float, val eyeDistance: Float, val confidence: Float)

// The oval sits a little above the middle of the frame and the eyes sit above
// the middle of a face, so a well-placed face has its eyes about here.
internal const val EYES_AT_Y = 0.40f
private const val CENTRE_SLACK_X = 0.13f
private const val CENTRE_SLACK_Y = 0.11f
// Eye distance as a share of the frame's width. A face is roughly 2.4 eye
// distances wide, so these put it between 40% and 80% of the width.
private const val EYES_TOO_FAR = 0.17f
private const val EYES_TOO_CLOSE = 0.34f
private const val MIN_CONFIDENCE = 0.4f

/** Guidance for a selfie from the faces found in a [width] by [height] frame. */
fun faceHint(faces: List<FaceReading>, width: Int, height: Int): Hint {
    val sure = faces.filter { it.confidence >= MIN_CONFIDENCE }
    if (sure.isEmpty()) return Hint.FIND_FACE
    if (sure.size > 1) return Hint.ONE_FACE
    val face = sure.single()
    val eyes = face.eyeDistance / width
    val dx = face.eyesX / width - 0.5f
    val dy = face.eyesY / height - EYES_AT_Y
    return when {
        dx < -CENTRE_SLACK_X || dx > CENTRE_SLACK_X || dy < -CENTRE_SLACK_Y || dy > CENTRE_SLACK_Y -> Hint.CENTRE_FACE
        eyes < EYES_TOO_FAR -> Hint.FACE_CLOSER
        eyes > EYES_TOO_CLOSE -> Hint.FACE_BACK
        else -> Hint.FACE_READY
    }
}

/**
 * Says whether an outline has stayed put. It compares each outline with the
 * one seen when it last settled, so a slow drift counts as movement too.
 */
class QuadSteadiness(private val tolerance: Float = 0.025f) {
    private var anchor: Quad? = null

    fun isSteady(quad: Quad?): Boolean {
        val held = anchor
        anchor = quad
        if (quad == null || held == null) return false
        if (quad.maxCornerDistance(held) > tolerance) return false
        anchor = held
        return true
    }
}

/**
 * Fills from 0 to 1 while a shot stays ready for [holdMs]. One missed frame
 * is forgiven, because a detector blinks; two start the count again.
 */
class HoldTimer(private val holdMs: Long) {
    private var since: Long? = null
    private var misses = 0

    fun update(ready: Boolean, nowMs: Long): Float {
        if (!ready) {
            if (++misses > 1) since = null
            return progress(nowMs)
        }
        misses = 0
        if (since == null) since = nowMs
        return progress(nowMs)
    }

    fun reset() {
        since = null
        misses = 0
    }

    private fun progress(nowMs: Long): Float {
        val start = since ?: return 0f
        return ((nowMs - start).toFloat() / holdMs).coerceIn(0f, 1f)
    }
}
