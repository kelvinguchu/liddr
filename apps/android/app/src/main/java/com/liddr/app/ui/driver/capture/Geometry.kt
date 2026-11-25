package com.liddr.app.ui.driver.capture

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Plain geometry for the document scanner. Nothing here touches Android, so it
// is tested on the JVM. Points are in pixels unless a function says "unit",
// which means 0..1 across the upright picture, the same for every resolution.

data class Pt(val x: Float, val y: Float) {
    operator fun minus(other: Pt) = Pt(x - other.x, y - other.y)
    fun distanceTo(other: Pt): Float = hypot(x - other.x, y - other.y)
}

/** A four-sided outline, clockwise on screen from the top-left corner. */
data class Quad(val topLeft: Pt, val topRight: Pt, val bottomRight: Pt, val bottomLeft: Pt) {
    val corners: List<Pt> get() = listOf(topLeft, topRight, bottomRight, bottomLeft)

    /** The enclosed area, by the shoelace formula. */
    fun area(): Float {
        val c = corners
        var twice = 0f
        for (i in c.indices) {
            val a = c[i]
            val b = c[(i + 1) % 4]
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2f
    }

    /** True when every corner turns the same way, so no side crosses another. */
    fun isConvex(): Boolean {
        val c = corners
        var sign = 0
        for (i in c.indices) {
            val a = c[i]
            val b = c[(i + 1) % 4]
            val d = c[(i + 2) % 4]
            val cross = (b.x - a.x) * (d.y - b.y) - (b.y - a.y) * (d.x - b.x)
            if (abs(cross) < 1e-6f) return false
            val turn = if (cross > 0) 1 else -1
            if (sign == 0) sign = turn else if (turn != sign) return false
        }
        return true
    }

    fun scaled(sx: Float, sy: Float) = map { Pt(it.x * sx, it.y * sy) }

    fun map(transform: (Pt) -> Pt) = Quad(transform(topLeft), transform(topRight), transform(bottomRight), transform(bottomLeft))

    /** The furthest any corner is from the same corner of [other]. */
    fun maxCornerDistance(other: Quad): Float = corners.zip(other.corners).maxOf { (a, b) -> a.distanceTo(b) }

    /** With one corner moved, kept inside the unit square. */
    fun withCorner(index: Int, to: Pt): Quad {
        val p = Pt(to.x.coerceIn(0f, 1f), to.y.coerceIn(0f, 1f))
        return when (index) {
            0 -> copy(topLeft = p)
            1 -> copy(topRight = p)
            2 -> copy(bottomRight = p)
            else -> copy(bottomLeft = p)
        }
    }

    companion object {
        /** A centred rectangle in unit space, [inset] in from every edge. */
        fun inset(inset: Float) = Quad(Pt(inset, inset), Pt(1 - inset, inset), Pt(1 - inset, 1 - inset), Pt(inset, 1 - inset))
    }
}

/**
 * Puts four points in order: clockwise on screen, starting from the corner
 * nearest the top-left. Returns null when they do not make a convex outline.
 */
fun orderCorners(points: List<Pt>): Quad? {
    if (points.size != 4) return null
    val cx = points.sumOf { it.x.toDouble() }.toFloat() / 4
    val cy = points.sumOf { it.y.toDouble() }.toFloat() / 4
    // With y pointing down, a growing angle runs clockwise on screen.
    val around = points.sortedBy { atan2(it.y - cy, it.x - cx) }
    val minX = points.minOf { it.x }
    val minY = points.minOf { it.y }
    val start = around.indices.minBy { hypot(around[it].x - minX, around[it].y - minY) }
    val quad = Quad(around[start], around[(start + 1) % 4], around[(start + 2) % 4], around[(start + 3) % 4])
    return quad.takeIf { it.isConvex() }
}

data class PixelSize(val width: Int, val height: Int)

/**
 * The size of the straightened page: as wide as the longer of its top and
 * bottom edges and as tall as the longer of its sides, shrunk to [maxEdge].
 */
fun outputSize(quad: Quad, maxEdge: Int): PixelSize {
    val width = max(quad.topLeft.distanceTo(quad.topRight), quad.bottomLeft.distanceTo(quad.bottomRight))
    val height = max(quad.topLeft.distanceTo(quad.bottomLeft), quad.topRight.distanceTo(quad.bottomRight))
    val scale = min(1f, maxEdge / max(width, height))
    return PixelSize(max(1, (width * scale).roundToInt()), max(1, (height * scale).roundToInt()))
}

/** A size that keeps its shape with its longer edge at most [maxEdge]. */
fun fitWithin(width: Int, height: Int, maxEdge: Int): PixelSize {
    val scale = min(1f, maxEdge.toFloat() / max(width, height))
    return PixelSize(max(1, (width * scale).roundToInt()), max(1, (height * scale).roundToInt()))
}

/** An upright greyscale picture, one byte per pixel, row by row. */
class GrayFrame(val pixels: ByteArray, val width: Int, val height: Int) {
    fun mean(): Int {
        if (pixels.isEmpty()) return 0
        var sum = 0L
        for (p in pixels) sum += p.toInt() and 0xFF
        return (sum / pixels.size).toInt()
    }
}

/**
 * Reads a camera's brightness plane into a small upright frame. [step] keeps
 * one pixel in that many, and [rotation] is how far clockwise the sensor's
 * picture must turn to stand upright (0, 90, 180 or 270).
 */
inline fun uprightGray(plane: (Int) -> Byte, rowStride: Int, pixelStride: Int, width: Int, height: Int, step: Int, rotation: Int): GrayFrame {
    val w = width / step
    val h = height / step
    val turned = rotation == 90 || rotation == 270
    val outW = if (turned) h else w
    val outH = if (turned) w else h
    val out = ByteArray(outW * outH)
    for (y in 0 until h) {
        val row = y * step * rowStride
        for (x in 0 until w) {
            val value = plane(row + x * step * pixelStride)
            val ox: Int
            val oy: Int
            when (rotation) {
                90 -> { ox = h - 1 - y; oy = x }
                180 -> { ox = w - 1 - x; oy = h - 1 - y }
                270 -> { ox = y; oy = w - 1 - x }
                else -> { ox = x; oy = y }
            }
            out[oy * outW + ox] = value
        }
    }
    return GrayFrame(out, outW, outH)
}

/** The black and white points that stretch a faded scan, from a 256-bin brightness count. */
data class Levels(val black: Int, val white: Int) {
    /** Multiply each channel by this… */
    val gain: Float get() = 255f / (white - black)

    /** …then add this. */
    val offset: Float get() = -black * gain
}

/**
 * A gentle clean-up: the darkest and brightest 1% set the range, but the range
 * never narrows below [minSpan], so a flat grey page is not turned into noise.
 */
fun levelsFor(histogram: IntArray, minSpan: Int = 170): Levels {
    val total = histogram.sum()
    if (total == 0) return Levels(0, 255)
    val clip = total / 100
    var black = 0
    var seen = 0
    while (black < 255 && seen + histogram[black] <= clip) seen += histogram[black++]
    var white = 255
    seen = 0
    while (white > 0 && seen + histogram[white] <= clip) seen += histogram[white--]
    // Ink is rarely pure black in a photo; do not crush more than a little of it.
    black = min(black, 60)
    white = max(white, black + 1)
    val missing = minSpan - (white - black)
    if (missing > 0) {
        white = min(255, white + missing)
        black = max(0, min(black, white - minSpan))
    }
    return Levels(black, white)
}
