package com.liddr.app.ui

import com.liddr.app.data.Application
import com.liddr.app.data.VerificationState
import com.liddr.app.ui.booking.RiderTab
import com.liddr.app.ui.booking.backFrom
import com.liddr.app.ui.driver.DriverBack
import com.liddr.app.ui.driver.DriverScreen
import com.liddr.app.ui.driver.DriverUiState
import com.liddr.app.ui.driver.driverBack
import org.junit.Assert.assertEquals
import org.junit.Test

/** Back steps to the screen you came from, and leaves the app only from a first screen. */
class BackTest {
    @Test
    fun riderTabs() {
        assertEquals("Trips goes back to Home", RiderTab.HOME, backFrom(RiderTab.TRIPS))
        assertEquals("Home leaves the app", null, backFrom(RiderTab.HOME))
    }

    @Test
    fun driverSetup() {
        val form = VerificationState("pending")
        val cases = listOf(
            Case("first vehicle choice leaves", DriverUiState(screen = DriverScreen.CATEGORY), DriverBack.LEAVE),
            Case("application form reopens the vehicles", DriverUiState(screen = DriverScreen.VERIFICATION, verification = form), DriverBack.CHANGE_VEHICLE),
            Case("rejected form reopens the vehicles", DriverUiState(screen = DriverScreen.VERIFICATION, verification = form.copy(application = Application("rejected"))), DriverBack.CHANGE_VEHICLE),
            Case("vehicles reopened from the form go back to it", DriverUiState(screen = DriverScreen.CATEGORY, changingVehicle = true), DriverBack.KEEP_VEHICLE),
            Case("documents leave, the application is in", DriverUiState(screen = DriverScreen.VERIFICATION, verification = form.copy(application = Application("pending"))), DriverBack.LEAVE),
            Case("documents in review leave", DriverUiState(screen = DriverScreen.VERIFICATION, verification = form.copy(application = Application("under_review"))), DriverBack.LEAVE),
            Case("suspended leaves", DriverUiState(screen = DriverScreen.VERIFICATION, verification = form.copy(application = Application("suspended"))), DriverBack.LEAVE),
            Case("home leaves", DriverUiState(screen = DriverScreen.HOME), DriverBack.LEAVE),
            Case("trip leaves", DriverUiState(screen = DriverScreen.TRIP), DriverBack.LEAVE),
        )
        val wrong = cases.filter { driverBack(it.state) != it.want }.map { "${it.name}: got ${driverBack(it.state)}, want ${it.want}" }
        assertEquals(emptyList<String>(), wrong)
    }

    private data class Case(val name: String, val state: DriverUiState, val want: DriverBack)
}
