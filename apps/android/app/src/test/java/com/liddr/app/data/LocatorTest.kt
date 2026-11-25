package com.liddr.app.data

import org.junit.Assert.assertEquals
import org.junit.Test

class LocatorTest {
    private data class Case(val name: String, val enabled: List<String>, val want: List<String>)

    // GPS gets no fix indoors, so asking it first left riders waiting 30 seconds
    // for nothing while the phone already knew where they were from Wi-Fi.
    @Test
    fun asksProvidersThatWorkIndoorsBeforeGps() {
        val cases = listOf(
            Case("fused first on Android 12 and newer", listOf("passive", "gps", "network", "fused"), listOf("fused", "network", "gps")),
            Case("network before gps without fused", listOf("gps", "network", "passive"), listOf("network", "gps")),
            Case("gps alone", listOf("gps"), listOf("gps")),
            Case("passive never answers a request", listOf("passive"), emptyList()),
        )
        for (case in cases) {
            assertEquals(case.name, case.want, locationProviders(case.enabled))
        }
    }
}
