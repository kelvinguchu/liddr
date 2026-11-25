package com.liddr.app.ui.driver.capture

import kotlin.random.Random
import org.junit.Assert.assertTrue
import org.junit.Test

class DocumentDetectorTest {
    private class Found(val name: String, val truth: Quad, val scene: Scene)

    private val upright = card(120f, 160f, 170f, 108f)
    private val tilted = card(120f, 160f, 160f, 100f, degrees = 12f)
    private val steep = card(118f, 150f, 150f, 95f, degrees = -27f)
    private val page = card(120f, 160f, 170f, 240f, degrees = 4f)
    // Seen from below: the far edge is shorter than the near one.
    private val leaning = Quad(Pt(62f, 96f), Pt(182f, 102f), Pt(204f, 214f), Pt(34f, 204f))

    private val found = listOf(
        Found("a card lying straight", upright, Scene().fill(upright, 215)),
        Found("a card turned a little", tilted, Scene().fill(tilted, 215)),
        Found("a card turned a lot", steep, Scene().fill(steep, 210)),
        Found("a card seen at an angle", leaning, Scene().fill(leaning, 215)),
        Found("a printed ID card", tilted, Scene().fill(tilted, 215).print(tilted, 60)),
        Found("a printed card seen at an angle", leaning, Scene().fill(leaning, 205).print(leaning, 70)),
        Found("a full page", page, Scene().fill(page, 225).print(page, 80)),
        Found("a dark card on a light table", tilted, Scene(background = 190).fill(tilted, 60)),
        Found("a faint card", upright, Scene(background = 110, texture = 8).fill(upright, 160)),
        Found("a card on a rough surface", tilted, Scene(texture = 28).fill(tilted, 220)),
        Found("a card under uneven light", tilted, Scene().fill(tilted, 215).print(tilted, 60).shade(dimmest = 0.45f)),
        Found("a card on a striped cloth", tilted, Scene().stripes(period = 24, tone = 120).fill(tilted, 215).print(tilted, 60)),
        Found("a page on a striped cloth", page, Scene().stripes(period = 16, tone = 110).fill(page, 225).print(page, 80)),
        Found("a card with a thumb over one edge", upright, Scene().fill(upright, 215).fill(card(120f, 216f, 34f, 44f), 120, grain = 10)),
    )

    @Test
    fun findsTheDocument() {
        val wrong = found.mapNotNull { case ->
            val detection = detectDocument(case.scene.frame()) ?: return@mapNotNull "${case.name}: found nothing"
            val off = detection.quad.maxCornerDistance(case.truth)
            when {
                off > 2f -> "${case.name}: got ${detection.quad}, want ${case.truth} (off by $off px)"
                detection.confidence < 0.75f -> "${case.name}: got confidence ${detection.confidence}, want at least 0.75"
                else -> null
            }
        }
        assertTrue(wrong.joinToString("\n"), wrong.isEmpty())
    }

    private class Nothing(val name: String, val frame: GrayFrame)

    private val nothing = listOf(
        Nothing("a blank frame", GrayFrame(ByteArray(SCENE_W * SCENE_H) { 128.toByte() }, SCENE_W, SCENE_H)),
        Nothing("a black frame", GrayFrame(ByteArray(SCENE_W * SCENE_H), SCENE_W, SCENE_H)),
        Nothing("a rough surface", Scene(texture = 28).frame()),
        Nothing("a striped cloth", Scene().stripes(period = 24, tone = 120).frame()),
        Nothing("pure noise", Random(3).let { r -> GrayFrame(ByteArray(SCENE_W * SCENE_H) { r.nextInt(256).toByte() }, SCENE_W, SCENE_H) }),
        Nothing("a card running off the side", Scene().fill(card(215f, 160f, 170f, 108f), 215).frame()),
        Nothing("a card running off a corner", Scene().fill(card(40f, 40f, 170f, 108f, degrees = 20f), 215).frame()),
        Nothing("the edge of a table", Scene().fill(Quad(Pt(-5f, 150f), Pt(245f, 170f), Pt(245f, 325f), Pt(-5f, 325f)), 200).frame()),
        Nothing("a strip across the frame", Scene().fill(Quad(Pt(-5f, 120f), Pt(245f, 120f), Pt(245f, 200f), Pt(-5f, 200f)), 210).frame()),
        Nothing("a card too far away", Scene().fill(card(120f, 160f, 44f, 28f), 215).frame()),
        Nothing("a frame too small to read", GrayFrame(ByteArray(16 * 16), 16, 16)),
    )

    @Test
    fun findsNothingWhenThereIsNoWholeDocument() {
        val wrong = nothing.mapNotNull { case -> detectDocument(case.frame)?.let { "${case.name}: got ${it.quad}, want nothing" } }
        assertTrue(wrong.joinToString("\n"), wrong.isEmpty())
    }
}
