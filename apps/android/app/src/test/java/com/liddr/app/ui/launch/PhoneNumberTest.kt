package com.liddr.app.ui.launch

import org.junit.Assert.assertEquals
import org.junit.Test

class PhoneNumberTest {
    @Test
    fun keepsTheNineNationalDigitsHoweverTyped() {
        val cases = mapOf(
            "0712 345 678" to "712345678",
            "+254 712 345 678" to "712345678",
            "254712345678" to "712345678",
            "712345678" to "712345678",
            "0712-345-6789" to "712345678",
            "" to "",
        )
        for ((typed, want) in cases) assertEquals(typed, want, nationalDigits(typed))
    }

    @Test
    fun showsWhereTheCodeWent() {
        assertEquals("+254 712 345 678", displayDestination("0712345678"))
        assertEquals("you@example.com", displayDestination("you@example.com"))
        assertEquals("0712", displayDestination("0712"))
    }
}
