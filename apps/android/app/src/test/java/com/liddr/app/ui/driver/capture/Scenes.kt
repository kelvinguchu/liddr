package com.liddr.app.ui.driver.capture

import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

// Drawn test pictures: a card lying on a rougher surface, as a phone sees it.

internal const val SCENE_W = 240
internal const val SCENE_H = 320

internal class Scene(val background: Int = 70, val texture: Int = 12, seed: Int = 7) {
    private val random = Random(seed)
    val pixels = IntArray(SCENE_W * SCENE_H) {
        // A grainy surface with a slow change in light from top to bottom.
        background + random.nextInt(-texture, texture + 1) + (it / SCENE_W) * 20 / SCENE_H
    }

    /** Fills a convex outline with one tone, softened by a little grain. */
    fun fill(quad: Quad, tone: Int, grain: Int = 3): Scene {
        val c = quad.corners
        for (y in 0 until SCENE_H) for (x in 0 until SCENE_W) {
            val inside = (0 until 4).all { i ->
                val a = c[i]
                val b = c[(i + 1) % 4]
                (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x) >= 0
            }
            if (inside) pixels[y * SCENE_W + x] = tone + random.nextInt(-grain, grain + 1)
        }
        return this
    }

    /** Printed lines and a photo box inside [card], placed by the card's own corners. */
    fun print(card: Quad, ink: Int): Scene {
        fun at(u: Float, v: Float): Pt {
            val top = Pt(card.topLeft.x + u * (card.topRight.x - card.topLeft.x), card.topLeft.y + u * (card.topRight.y - card.topLeft.y))
            val bottom = Pt(card.bottomLeft.x + u * (card.bottomRight.x - card.bottomLeft.x), card.bottomLeft.y + u * (card.bottomRight.y - card.bottomLeft.y))
            return Pt(top.x + v * (bottom.x - top.x), top.y + v * (bottom.y - top.y))
        }
        fill(Quad(at(0.08f, 0.2f), at(0.32f, 0.2f), at(0.32f, 0.8f), at(0.08f, 0.8f)), ink)
        for (row in 0 until 5) {
            val v = 0.22f + row * 0.13f
            fill(Quad(at(0.4f, v), at(0.9f, v), at(0.9f, v + 0.04f), at(0.4f, v + 0.04f)), ink)
        }
        return this
    }

    /** Light falling off from left to right, down to [dimmest] of full brightness. */
    fun shade(dimmest: Float): Scene {
        for (i in pixels.indices) pixels[i] = (pixels[i] * (1f - (1f - dimmest) * (i % SCENE_W) / SCENE_W)).toInt()
        return this
    }

    /** A striped cloth: bands [period] pixels apart running down the frame. */
    fun stripes(period: Int, tone: Int): Scene {
        for (i in pixels.indices) if ((i % SCENE_W) % period < period / 2) pixels[i] = tone + random.nextInt(-4, 5)
        return this
    }

    fun frame() = GrayFrame(ByteArray(pixels.size) { pixels[it].coerceIn(0, 255).toByte() }, SCENE_W, SCENE_H)
}

/** A [w] by [h] card centred on ([cx], [cy]) and turned [degrees] clockwise. */
internal fun card(cx: Float, cy: Float, w: Float, h: Float, degrees: Float = 0f): Quad {
    val a = Math.toRadians(degrees.toDouble())
    fun corner(dx: Float, dy: Float) = Pt((cx + dx * cos(a) - dy * sin(a)).toFloat(), (cy + dx * sin(a) + dy * cos(a)).toFloat())
    return Quad(corner(-w / 2, -h / 2), corner(w / 2, -h / 2), corner(w / 2, h / 2), corner(-w / 2, h / 2))
}
