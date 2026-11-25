package com.liddr.app.ui.booking

import com.liddr.app.data.Coordinates
import com.liddr.app.data.HistoryItem
import com.liddr.app.data.Place
import java.util.Locale
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Test

class HomeTextTest {
    @Test
    fun greetsByTimeOfDay() {
        val cases = mapOf(5 to "Good morning", 11 to "Good morning", 12 to "Good afternoon", 16 to "Good afternoon", 17 to "Good evening", 2 to "Good evening")
        for ((hour, want) in cases) assertEquals("$hour", want, greeting(hour))
    }

    @Test
    fun showsTripTimesInTheLocalZone() {
        val before = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("Africa/Nairobi"))
        try {
            assertEquals("Fri 13 Nov, 17:16", tripDate("2026-11-13T14:16:05Z", Locale.UK))
            assertEquals("Fri 13 Nov, 17:16", tripDate("2026-11-13T14:16:05.123456Z", Locale.UK))
            assertEquals("Fri 13 Nov, 17:16", tripDate("2026-11-13T17:16:05+03:00", Locale.UK))
            assertEquals("", tripDate("not a date", Locale.UK))
        } finally {
            TimeZone.setDefault(before)
        }
    }

    @Test
    fun recentPlacesAreNamedDestinationsEachOnce() {
        val yaya = Coordinates(-1.2925, 36.7875)
        val jkia = Coordinates(-1.3192, 36.9278)
        val state = HomeUiState(
            recent = listOf(
                HistoryItem("a", dropoff = yaya, status = "completed"),
                HistoryItem("b", dropoff = jkia, status = "completed"),
                HistoryItem("c", dropoff = yaya, status = "cancelled"),
                HistoryItem("d", dropoff = null, status = "completed"), // a driver's history has no places
                HistoryItem("e", dropoff = jkia, status = "completed"), // not named yet
            ),
            names = mapOf("a" to "Yaya Centre", "b" to "JKIA", "c" to "Yaya Centre"),
        )
        assertEquals(listOf(Place("Yaya Centre", "", yaya), Place("JKIA", "", jkia)), recentPlaces(state))
    }
}
