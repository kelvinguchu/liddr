package com.liddr.app.data

import java.security.MessageDigest
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SmsCodeTest {
    @Test
    fun readsTheCodeFromBothMessageShapes() {
        val cases = mapOf(
            "app" to "Your Liddr code is: 409117\nIt expires in 5 minutes. Do not share it.\n\nAB12cd3Ef+/",
            "browser" to "Your Liddr code is: 409117\nIt expires in 5 minutes. Do not share it.\n\n@liddr.app #409117",
        )
        for ((name, message) in cases) assertEquals(name, "409117", codeFromSms(message))
        assertNull(codeFromSms("Your M-PESA balance is 409117"))
    }

    @Test
    fun hashMatchesGooglesRecipe() {
        val cases = listOf("com.liddr.app" to "3082abcd", "com.liddr.app" to "ffff", "a" to "")
        for ((pkg, signature) in cases) {
            val digest = MessageDigest.getInstance("SHA-256").digest("$pkg $signature".toByteArray())
            val want = Base64.getEncoder().withoutPadding().encodeToString(digest.copyOf(9)).take(11)
            assertEquals("$pkg/$signature", want, appHash(pkg, signature))
        }
    }
}
