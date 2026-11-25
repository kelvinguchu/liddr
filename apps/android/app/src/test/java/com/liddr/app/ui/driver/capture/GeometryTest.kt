package com.liddr.app.ui.driver.capture

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GeometryTest {
    private val tl = Pt(10f, 20f)
    private val tr = Pt(110f, 25f)
    private val br = Pt(120f, 90f)
    private val bl = Pt(5f, 80f)

    @Test
    fun ordersCornersClockwiseFromTopLeft() {
        val want = Quad(tl, tr, br, bl)
        val cases = mapOf(
            "already in order" to listOf(tl, tr, br, bl),
            "reversed" to listOf(bl, br, tr, tl),
            "crossed" to listOf(tl, br, tr, bl),
            "starting elsewhere" to listOf(br, bl, tl, tr),
        )
        for ((name, points) in cases) assertEquals(name, want, orderCorners(points))
    }

    @Test
    fun refusesPointsThatAreNotAnOutline() {
        val cases = mapOf(
            "three points" to listOf(tl, tr, br),
            "a dent" to listOf(Pt(0f, 0f), Pt(100f, 0f), Pt(30f, 30f), Pt(0f, 100f)),
            "a straight line" to listOf(Pt(0f, 0f), Pt(10f, 0f), Pt(20f, 0f), Pt(30f, 0f)),
        )
        for ((name, points) in cases) assertNull(name, orderCorners(points))
    }

    @Test
    fun measuresAreaAndConvexity() {
        val square = Quad(Pt(0f, 0f), Pt(10f, 0f), Pt(10f, 10f), Pt(0f, 10f))
        assertEquals(100f, square.area(), 0.001f)
        assertTrue(square.isConvex())
        assertFalse("a bow tie", Quad(Pt(0f, 0f), Pt(10f, 10f), Pt(10f, 0f), Pt(0f, 10f)).isConvex())
        assertEquals(0.64f, Quad.inset(0.1f).area(), 0.001f)
    }

    @Test
    fun sizesTheStraightenedPage() {
        val leaning = Quad(Pt(100f, 0f), Pt(900f, 0f), Pt(1000f, 600f), Pt(0f, 600f))
        val cases = listOf(
            Triple("kept when small", 4000, PixelSize(1000, 608)),
            Triple("shrunk to the limit", 500, PixelSize(500, 304)),
        )
        for ((name, maxEdge, want) in cases) assertEquals(name, want, outputSize(leaning, maxEdge))
        assertEquals(PixelSize(2048, 1536), fitWithin(4000, 3000, 2048))
        assertEquals(PixelSize(800, 600), fitWithin(800, 600, 2048))
    }

    @Test
    fun keepsADraggedCornerInsideThePicture() {
        val moved = Quad.inset(0.1f).withCorner(2, Pt(1.4f, -0.2f))
        assertEquals(Pt(1f, 0f), moved.bottomRight)
        assertEquals(Pt(0.1f, 0.1f), moved.topLeft)
    }

    // A 3 by 2 sensor picture:  1 2 3
    //                           4 5 6
    private val sensor = byteArrayOf(1, 2, 3, 4, 5, 6)

    @Test
    fun turnsTheSensorPictureUpright() {
        class Case(val rotation: Int, val width: Int, val height: Int, val pixels: ByteArray)
        val cases = listOf(
            Case(0, 3, 2, byteArrayOf(1, 2, 3, 4, 5, 6)),
            Case(90, 2, 3, byteArrayOf(4, 1, 5, 2, 6, 3)),
            Case(180, 3, 2, byteArrayOf(6, 5, 4, 3, 2, 1)),
            Case(270, 2, 3, byteArrayOf(3, 6, 2, 5, 1, 4)),
        )
        for (case in cases) {
            val got = uprightGray({ sensor[it] }, rowStride = 3, pixelStride = 1, width = 3, height = 2, step = 1, rotation = case.rotation)
            assertEquals("rotation ${case.rotation}", case.width to case.height, got.width to got.height)
            assertArrayEquals("rotation ${case.rotation}", case.pixels, got.pixels)
        }
    }

    @Test
    fun skipsPaddingAndPixelsWhenShrinking() {
        // Four pixels a row, two bytes apart, with two bytes of padding after each row.
        val padded = ByteArray(40) { (it / 2).toByte() }
        val got = uprightGray({ padded[it] }, rowStride = 10, pixelStride = 2, width = 4, height = 4, step = 2, rotation = 0)
        assertArrayEquals(byteArrayOf(0, 2, 10, 12), got.pixels)
    }

    @Test
    fun stretchesLevelsGently() {
        fun histogram(vararg tones: Pair<Int, Int>) = IntArray(256).also { h -> tones.forEach { (tone, count) -> h[tone] = count } }
        val cases = listOf(
            Triple("a faded scan is stretched", histogram(40 to 500, 200 to 9500), Levels(40, 210)),
            Triple("a flat grey page is left nearly alone", histogram(128 to 10000), Levels(60, 230)),
            Triple("deep shadows are not crushed", histogram(100 to 5000, 250 to 5000), Levels(60, 250)),
            Triple("an empty picture is unchanged", IntArray(256), Levels(0, 255)),
        )
        for ((name, histogram, want) in cases) assertEquals(name, want, levelsFor(histogram))
    }
}
