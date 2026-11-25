package com.liddr.app.ui.driver.capture

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

// Finds a document's outline in a small greyscale frame. Liddr's own code, no
// vision library: smooth the frame, find thin edges, let the edges vote for
// straight lines, then pick the four lines whose outline the edges back best.
// Plain Kotlin, so the tests run on the JVM against drawn pictures.

/** A document's outline in the frame's pixels, and how much of it the edges back (0..1). */
class Detection(val quad: Quad, val confidence: Float)

// Slope is brightness change per pixel after smoothing. A clean edge between
// two tones scores about 0.28 of their difference, so this needs about 12 levels.
private const val MIN_SLOPE = 3.5f
private const val RELATIVE_SLOPE = 0.25f
private const val THETA_BINS = 90
private const val THETA_STEP = PI.toFloat() / THETA_BINS
private const val RHO_STEP = 2
// Enough that a patterned surface's lines do not crowd out the document's own four.
private const val MAX_LINES = 24
private const val MAX_PEAK_TRIES = 60
private const val MIN_LINE_SHARE = 0.16f
private const val MIN_AREA_SHARE = 0.08f
private const val MIN_SIDE_SHARE = 0.15f
private const val MIN_OPPOSITE_RATIO = 0.4f
private const val MIN_SIDE_SUPPORT = 0.4f
private const val MIN_MEAN_SUPPORT = 0.6f
private val COS_PARALLEL = cos(35.0 * PI / 180).toFloat()
private val COS_CROSSING = cos(50.0 * PI / 180).toFloat()
private val COS_ALIGNED = cos(25.0 * PI / 180).toFloat()

/** Returns the document in [frame], or null when nothing in it looks like one whole document. */
fun detectDocument(frame: GrayFrame): Detection? {
    if (frame.width < 32 || frame.height < 32) return null
    val edges = Edges.find(frame) ?: return null
    val lines = houghLines(edges)
    if (lines.size < 4) return null
    val best = bestOutline(lines, edges) ?: return null
    return Detection(refine(best.quad, edges), best.support)
}

/** Thin edges: where they are, and the unit direction brightness rises across each. */
private class Edges(val width: Int, val height: Int, val at: IntArray, val ux: FloatArray, val uy: FloatArray) {
    fun isEdge(x: Int, y: Int) = x in 0 until width && y in 0 until height && (ux[y * width + x] != 0f || uy[y * width + x] != 0f)

    companion object {
        fun find(frame: GrayFrame): Edges? {
            val w = frame.width
            val h = frame.height
            val raw = IntArray(w * h) { frame.pixels[it].toInt() and 0xFF }
            val smooth = box3(box3(raw, w, h), w, h)
            val gx = FloatArray(w * h)
            val gy = FloatArray(w * h)
            val slope = FloatArray(w * h)
            val counts = IntArray(512)
            for (y in 1 until h - 1) for (x in 1 until w - 1) {
                val i = y * w + x
                val dx = smooth[i - w + 1] + 2 * smooth[i + 1] + smooth[i + w + 1] - smooth[i - w - 1] - 2 * smooth[i - 1] - smooth[i + w - 1]
                val dy = smooth[i + w - 1] + 2 * smooth[i + w] + smooth[i + w + 1] - smooth[i - w - 1] - 2 * smooth[i - w] - smooth[i - w + 1]
                gx[i] = dx / 8f
                gy[i] = dy / 8f
                slope[i] = hypot(gx[i], gy[i])
                counts[min(511, (slope[i] * 2).toInt())]++
            }
            // The strongest 1% of slopes is about where a document's sides sit.
            var bin = 511
            var seen = 0
            val top = w * h / 100
            while (bin > 0 && seen + counts[bin] < top) seen += counts[bin--]
            val threshold = max(MIN_SLOPE, RELATIVE_SLOPE * bin / 2f)
            val at = IntArray(w * h)
            var count = 0
            val ux = FloatArray(w * h)
            val uy = FloatArray(w * h)
            for (y in 1 until h - 1) for (x in 1 until w - 1) {
                val i = y * w + x
                val s = slope[i]
                if (s < threshold) continue
                // Keep only the crest of each edge, so a line is one pixel thick.
                val ax = abs(gx[i])
                val ay = abs(gy[i])
                val step = when {
                    ax > 2.414f * ay -> 1
                    ay > 2.414f * ax -> w
                    (gx[i] > 0) == (gy[i] > 0) -> w + 1
                    else -> w - 1
                }
                if (s <= slope[i - step] || s < slope[i + step]) continue
                ux[i] = gx[i] / s
                uy[i] = gy[i] / s
                at[count++] = i
            }
            return if (count == 0) null else Edges(w, h, at.copyOf(count), ux, uy)
        }

        private fun box3(src: IntArray, w: Int, h: Int): IntArray {
            val across = IntArray(w * h)
            for (y in 0 until h) for (x in 0 until w) {
                val i = y * w + x
                across[i] = src[if (x > 0) i - 1 else i] + src[i] + src[if (x < w - 1) i + 1 else i]
            }
            val out = IntArray(w * h)
            for (y in 0 until h) for (x in 0 until w) {
                val i = y * w + x
                out[i] = (across[if (y > 0) i - w else i] + across[i] + across[if (y < h - 1) i + w else i]) / 9
            }
            return out
        }
    }
}

/** A straight line as x·cos + y·sin = rho. */
private class Line(val cos: Float, val sin: Float, val rho: Float) {
    fun meet(other: Line): Pt? {
        val det = cos * other.sin - other.cos * sin
        if (abs(det) < 1e-4f) return null
        return Pt((rho * other.sin - other.rho * sin) / det, (cos * other.rho - other.cos * rho) / det)
    }

    /** 1 when the two run the same way, 0 when they cross at right angles. */
    fun alignment(other: Line) = abs(cos * other.cos + sin * other.sin)
}

/** Each edge pixel votes for the lines it could lie on; the best-backed lines win. */
private fun houghLines(edges: Edges): List<Line> {
    val reach = hypot(edges.width.toFloat(), edges.height.toFloat()).toInt() + 1
    val rhoBins = 2 * reach / RHO_STEP + 1
    val cosines = FloatArray(THETA_BINS) { cos(it * THETA_STEP) }
    val sines = FloatArray(THETA_BINS) { sin(it * THETA_STEP) }
    val votes = IntArray(THETA_BINS * rhoBins)
    for (i in edges.at) {
        val x = i % edges.width
        val y = i / edges.width
        // An edge only backs lines that run along it, which keeps texture out.
        var angle = atan2(edges.uy[i], edges.ux[i])
        if (angle < 0) angle += PI.toFloat()
        val bin = (angle / THETA_STEP).roundToInt()
        for (near in bin - 1..bin + 1) {
            val t = Math.floorMod(near, THETA_BINS)
            val rho = x * cosines[t] + y * sines[t]
            votes[t * rhoBins + ((rho + reach) / RHO_STEP).roundToInt()]++
        }
    }
    val needed = (MIN_LINE_SHARE * min(edges.width, edges.height)).toInt()
    val lines = ArrayList<Line>(MAX_LINES)
    var tries = 0
    while (lines.size < MAX_LINES && tries++ < MAX_PEAK_TRIES) {
        var best = 0
        for (i in votes.indices) if (votes[i] > votes[best]) best = i
        val t = best / rhoBins
        val r = best % rhoBins
        // A line rarely falls in one bin exactly, so count the bin with its two neighbours.
        val backing = votes[best] + (if (r > 0) votes[best - 1] else 0) + (if (r < rhoBins - 1) votes[best + 1] else 0)
        if (backing < needed) {
            // Too weak, but a line split evenly between two bins can still be waiting below it.
            if (votes[best] * 3 < needed) break
            votes[best] = 0
            continue
        }
        val rough = Line(cosines[t], sines[t], (r * RHO_STEP - reach).toFloat())
        lines += fit(edges, rough.cos, rough.sin) { x, y -> abs(x * rough.cos + y * rough.sin - rough.rho) <= FIT_REACH } ?: rough
        // Clear the neighbourhood so one edge is not counted as several lines.
        for (dt in -4..4) for (dr in -5..5) {
            var tt = t + dt
            var rr = r + dr
            if (tt < 0 || tt >= THETA_BINS) {
                // Half a turn on, the same line has the opposite rho.
                tt = Math.floorMod(tt, THETA_BINS)
                rr = rhoBins - 1 - r + dr
            }
            if (rr in 0 until rhoBins) votes[tt * rhoBins + rr] = 0
        }
    }
    return lines
}

private class Outline(val quad: Quad, val support: Float, val score: Float)

/** Tries every two pairs of facing lines and keeps the outline the edges back best. */
private fun bestOutline(lines: List<Line>, edges: Edges): Outline? {
    val w = edges.width.toFloat()
    val h = edges.height.toFloat()
    val slack = 0.02f * max(w, h)
    val pairs = ArrayList<Pair<Line, Line>>()
    for (a in lines.indices) for (b in a + 1 until lines.size) {
        if (lines[a].alignment(lines[b]) >= COS_PARALLEL) pairs += lines[a] to lines[b]
    }
    var best: Outline? = null
    for (p in pairs.indices) for (q in p + 1 until pairs.size) {
        val (a, b) = pairs[p]
        val (c, d) = pairs[q]
        if (a === c || a === d || b === c || b === d) continue
        if (max(max(a.alignment(c), a.alignment(d)), max(b.alignment(c), b.alignment(d))) > COS_CROSSING) continue
        val corners = listOf(a.meet(c), a.meet(d), b.meet(c), b.meet(d)).filterNotNull()
        if (corners.any { it.x < -slack || it.y < -slack || it.x > w + slack || it.y > h + slack }) continue
        val quad = orderCorners(corners) ?: continue
        if (!plausible(quad, w, h)) continue
        val outline = measure(quad, edges) ?: continue
        if (best == null || outline.score > best.score) best = outline
    }
    return best
}

private fun plausible(quad: Quad, w: Float, h: Float): Boolean {
    if (quad.area() < MIN_AREA_SHARE * w * h) return false
    val top = quad.topLeft.distanceTo(quad.topRight)
    val bottom = quad.bottomLeft.distanceTo(quad.bottomRight)
    val left = quad.topLeft.distanceTo(quad.bottomLeft)
    val right = quad.topRight.distanceTo(quad.bottomRight)
    if (min(min(top, bottom), min(left, right)) < MIN_SIDE_SHARE * min(w, h)) return false
    return min(top, bottom) / max(top, bottom) >= MIN_OPPOSITE_RATIO && min(left, right) / max(left, right) >= MIN_OPPOSITE_RATIO
}

/**
 * Walks each side and counts how much of it lies on an edge running the same
 * way. A real document is also lighter than what is around it on every side,
 * or darker on every side; an outline pieced together from a pattern is not.
 */
private fun measure(quad: Quad, edges: Edges): Outline? {
    val c = quad.corners
    var total = 0f
    var lighterInside = 0
    for (side in 0 until 4) {
        val from = c[side]
        val to = c[(side + 1) % 4]
        val length = from.distanceTo(to)
        // Corners run clockwise on screen, so this normal points into the outline.
        val nx = -(to.y - from.y) / length
        val ny = (to.x - from.x) / length
        val samples = max(8, (length / 2).toInt())
        var hits = 0
        var polarity = 0f
        for (s in 0 until samples) {
            // Skip the ends: cards have rounded corners.
            val t = 0.08f + 0.84f * (s + 0.5f) / samples
            val px = from.x + t * (to.x - from.x)
            val py = from.y + t * (to.y - from.y)
            for (off in SUPPORT_OFFSETS) {
                val x = (px + off * nx).roundToInt()
                val y = (py + off * ny).roundToInt()
                if (!edges.isEdge(x, y)) continue
                val along = edges.ux[y * edges.width + x] * nx + edges.uy[y * edges.width + x] * ny
                if (abs(along) < COS_ALIGNED) continue
                hits++
                polarity += along
                break
            }
        }
        val support = hits.toFloat() / samples
        if (support < MIN_SIDE_SUPPORT) return null
        total += support
        if (polarity > 0) lighterInside++
    }
    val mean = total / 4
    if (mean < MIN_MEAN_SUPPORT || lighterInside in 1..3) return null
    // Between two well-backed outlines, prefer the larger: the page, not a box printed on it.
    val share = quad.area() / (edges.width * edges.height)
    return Outline(quad, mean, mean * mean * share.pow(0.25f))
}

private val SUPPORT_OFFSETS = intArrayOf(0, -1, 1, -2, 2)

/** Fits each side to the edge pixels along it, which places corners more finely than the vote does. */
private fun refine(quad: Quad, edges: Edges): Quad {
    val c = quad.corners
    val sides = (0 until 4).map { fitSide(c[it], c[(it + 1) % 4], edges) ?: return quad }
    val corners = (0 until 4).map { sides[(it + 3) % 4].meet(sides[it]) ?: return quad }
    val fitted = Quad(corners[0], corners[1], corners[2], corners[3])
    return if (fitted.isConvex() && fitted.maxCornerDistance(quad) <= MAX_REFINE_SHIFT) fitted else quad
}

private const val MAX_REFINE_SHIFT = 6f

private fun fitSide(from: Pt, to: Pt, edges: Edges): Line? {
    val length = from.distanceTo(to)
    val dx = (to.x - from.x) / length
    val dy = (to.y - from.y) / length
    return fit(edges, -dy, dx) { x, y ->
        val along = (x - from.x) * dx + (y - from.y) * dy
        along >= 0.05f * length && along <= 0.95f * length && abs(-(x - from.x) * dy + (y - from.y) * dx) <= FIT_REACH
    }
}

private const val FIT_REACH = 3f

/**
 * The line that best fits the edge pixels [near] a rough line whose normal is
 * ([nx], [ny]): through their centre, along their longest spread.
 */
private inline fun fit(edges: Edges, nx: Float, ny: Float, near: (Float, Float) -> Boolean): Line? {
    var n = 0
    var sx = 0.0
    var sy = 0.0
    var sxx = 0.0
    var syy = 0.0
    var sxy = 0.0
    for (i in edges.at) {
        if (abs(edges.ux[i] * nx + edges.uy[i] * ny) < COS_ALIGNED) continue
        val x = (i % edges.width).toFloat()
        val y = (i / edges.width).toFloat()
        if (!near(x, y)) continue
        n++
        sx += x
        sy += y
        sxx += x * x
        syy += y * y
        sxy += x * y
    }
    if (n < 10) return null
    val mx = sx / n
    val my = sy / n
    val angle = 0.5 * atan2(2 * (sxy / n - mx * my), (sxx / n - mx * mx) - (syy / n - my * my))
    val fx = -sin(angle).toFloat()
    val fy = cos(angle).toFloat()
    return Line(fx, fy, (mx * fx + my * fy).toFloat())
}
