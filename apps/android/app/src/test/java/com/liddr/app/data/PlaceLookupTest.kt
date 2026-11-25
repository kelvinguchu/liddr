package com.liddr.app.data

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaceLookupTest {
    @Test
    fun aReplacedSearchIsNotAnOutage() = runTest {
        // Each keystroke cancels the search before it. That was shown as "Place search isn't available".
        val thrown = runCatching { placeLookup<Unit> { throw CancellationException("replaced by the next keystroke") } }.exceptionOrNull()
        assertTrue("got $thrown", thrown is CancellationException && thrown !is PlaceSearchUnavailable)
    }

    @Test
    fun aProviderFailureIsAnOutage() = runTest {
        val thrown = runCatching { placeLookup<Unit> { throw IOException("no network") } }.exceptionOrNull()
        assertTrue("got $thrown", thrown is PlaceSearchUnavailable)
    }

    @Test
    fun anAnswerPassesThrough() = runTest {
        assertEquals("Yaya Centre", placeLookup { "Yaya Centre" })
    }

    @Test
    fun aResultsDetailDoesNotRepeatItsName() {
        val cases = listOf(
            Triple("Yaya Centre", "Yaya Centre, Argwings Kodhek Road, Nairobi, Kenya", "Argwings Kodhek Road, Nairobi, Kenya"),
            Triple("Yaya centre", "Yaya Centre, Nairobi, Kenya", "Nairobi, Kenya"),
            Triple("JKIA", "Jomo Kenyatta International Airport, Nairobi, Kenya", "Jomo Kenyatta International Airport, Nairobi, Kenya"),
            Triple("Westlands", "Westlands", ""),
        )
        for ((title, full, want) in cases) assertEquals(title, want, placeDetail(title, full))
    }
}
