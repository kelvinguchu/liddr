package com.liddr.app.ui.booking

import com.google.android.gms.maps.model.LatLng
import org.junit.Assert.assertEquals
import org.junit.Test

class MapMathTest {
    private val nairobi = LatLng(-1.2864, 36.8172)

    @Test
    fun headingPointsTheWayTheDriverMoved() {
        val cases = mapOf(
            "north" to (LatLng(-1.2854, 36.8172) to 0f),
            "east" to (LatLng(-1.2864, 36.8182) to 90f),
            "south" to (LatLng(-1.2874, 36.8172) to 180f),
            "west" to (LatLng(-1.2864, 36.8162) to 270f),
        )
        for ((name, case) in cases) assertEquals(name, case.second, headingDegrees(nairobi, case.first), 0.5f)
    }

    @Test
    fun measuresShortDistances() {
        // 0.001 degrees of latitude is about 111 metres anywhere.
        assertEquals(111.3, metresBetween(nairobi, LatLng(-1.2854, 36.8172)), 0.5)
        assertEquals(0.0, metresBetween(nairobi, nairobi), 0.001)
    }
}
