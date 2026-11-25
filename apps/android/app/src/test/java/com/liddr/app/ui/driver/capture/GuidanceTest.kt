package com.liddr.app.ui.driver.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GuidanceTest {
    @Test
    fun guidesADocument() {
        class Case(val name: String, val quad: Quad?, val brightness: Int, val want: Hint)
        val cases = listOf(
            Case("nothing found", null, 120, Hint.FIND_DOCUMENT),
            Case("nothing found in the dark", null, 20, Hint.TOO_DARK),
            Case("found but small", Quad.inset(0.35f), 120, Hint.MOVE_CLOSER),
            Case("found and large", Quad.inset(0.15f), 120, Hint.HOLD_STEADY),
            Case("found in poor light", Quad.inset(0.15f), 20, Hint.HOLD_STEADY),
        )
        for (case in cases) assertEquals(case.name, case.want, documentHint(case.quad, case.brightness))
    }

    @Test
    fun guidesASelfie() {
        val good = FaceReading(eyesX = 120f, eyesY = 128f, eyeDistance = 60f, confidence = 0.6f)
        class Case(val name: String, val faces: List<FaceReading>, val want: Hint)
        val cases = listOf(
            Case("no face", emptyList(), Hint.FIND_FACE),
            Case("an unsure face", listOf(good.copy(confidence = 0.2f)), Hint.FIND_FACE),
            Case("two faces", listOf(good, good.copy(eyesX = 40f)), Hint.ONE_FACE),
            Case("a second, unsure face is ignored", listOf(good, good.copy(confidence = 0.1f)), Hint.FACE_READY),
            Case("off to the left", listOf(good.copy(eyesX = 60f)), Hint.CENTRE_FACE),
            Case("too low", listOf(good.copy(eyesY = 230f)), Hint.CENTRE_FACE),
            Case("too far", listOf(good.copy(eyeDistance = 25f)), Hint.FACE_CLOSER),
            Case("too close", listOf(good.copy(eyeDistance = 100f)), Hint.FACE_BACK),
            Case("well placed", listOf(good), Hint.FACE_READY),
        )
        for (case in cases) assertEquals(case.name, case.want, faceHint(case.faces, width = 240, height = 320))
    }

    @Test
    fun onlyReadyHintsAllowAShot() {
        val ready = Hint.entries.filter { it.ready }.toSet()
        assertEquals(setOf(Hint.HOLD_STEADY, Hint.FRAME_VEHICLE, Hint.FACE_READY), ready)
    }

    @Test
    fun noticesWhenAnOutlineMoves() {
        val steadiness = QuadSteadiness(tolerance = 0.02f)
        val still = Quad.inset(0.2f)
        assertFalse("the first sighting", steadiness.isSteady(still))
        assertTrue("the same again", steadiness.isSteady(still))
        assertTrue("a tremble", steadiness.isSteady(still.withCorner(0, Pt(0.21f, 0.2f))))
        assertFalse("a jump", steadiness.isSteady(Quad.inset(0.3f)))
        assertTrue("settled in the new place", steadiness.isSteady(Quad.inset(0.3f)))
        assertFalse("lost", steadiness.isSteady(null))
        assertFalse("found again", steadiness.isSteady(still))
    }

    @Test
    fun aSlowDriftIsMovement() {
        val steadiness = QuadSteadiness(tolerance = 0.02f)
        steadiness.isSteady(Quad.inset(0.2f))
        assertTrue(steadiness.isSteady(Quad.inset(0.21f)))
        assertFalse("drifted past the tolerance from where it settled", steadiness.isSteady(Quad.inset(0.222f)))
    }

    @Test
    fun fillsWhileAShotIsHeld() {
        val timer = HoldTimer(holdMs = 1000)
        assertEquals("not ready", 0f, timer.update(false, 0), 0f)
        assertEquals("just ready", 0f, timer.update(true, 100), 0f)
        assertEquals("half way", 0.5f, timer.update(true, 600), 0.001f)
        assertEquals("one blink is forgiven", 0.6f, timer.update(false, 700), 0.001f)
        assertEquals("still counting", 0.8f, timer.update(true, 900), 0.001f)
        assertEquals("full", 1f, timer.update(true, 5000), 0f)
        timer.update(false, 5100)
        assertEquals("two misses start again", 0f, timer.update(false, 5200), 0f)
        assertEquals("from the beginning", 0f, timer.update(true, 5300), 0f)
        assertEquals(0.2f, timer.update(true, 5500), 0.001f)
        timer.reset()
        assertEquals("after a reset", 0f, timer.update(true, 6000), 0f)
    }

    @Test
    fun hintsAreAFewWordsAtMost() {
        // A camera is glanced at while holding the phone still: a hint is read in one look.
        val long = Hint.entries.filter { it.text.split(" ").size > MAX_HINT_WORDS }.map { it.text }
        assertEquals(emptyList<String>(), long)
    }

    private companion object {
        const val MAX_HINT_WORDS = 4
    }
}
