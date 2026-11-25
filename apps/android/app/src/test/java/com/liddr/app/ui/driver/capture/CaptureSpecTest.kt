package com.liddr.app.ui.driver.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureSpecTest {
    // Every document type the API's verification list can ask for.
    private val kinds = mapOf(
        "national_id_front" to CaptureKind.DOCUMENT,
        "national_id_back" to CaptureKind.DOCUMENT,
        "drivers_licence" to CaptureKind.DOCUMENT,
        "psv_badge" to CaptureKind.DOCUMENT,
        "good_conduct_certificate" to CaptureKind.DOCUMENT,
        "vehicle_logbook" to CaptureKind.DOCUMENT,
        "commercial_insurance" to CaptureKind.DOCUMENT,
        "vehicle_photo_front" to CaptureKind.PHOTO,
        "vehicle_photo_back" to CaptureKind.PHOTO,
        "vehicle_photo_side" to CaptureKind.PHOTO,
        "driver_selfie_liveness" to CaptureKind.SELFIE,
        "something_added_later" to CaptureKind.DOCUMENT,
    )

    @Test
    fun picksTheCameraForEachDocumentType() {
        for ((type, want) in kinds) assertEquals(type, want, captureSpec(type, "Label").kind)
    }

    @Test
    fun everyCameraHasWordsForTheDriver() {
        for (type in kinds.keys) {
            val spec = captureSpec(type, "Label")
            assertTrue("$type: title", spec.title.isNotBlank())
        }
    }

    @Test
    fun theSelfieDoesNotClaimToProveAPersonIsReal() {
        val words = captureSpec("driver_selfie_liveness", "Selfie").title + Hint.entries.joinToString(" ") { it.text }
        for (claim in listOf("liveness", "live person", "real person", "spoof")) assertTrue(claim, !words.contains(claim, ignoreCase = true))
    }

    @Test
    fun turnsSidewaysCardsLeft() {
        class Case(val name: String, val type: String, val width: Int, val height: Int, val want: Int)
        val cases = listOf(
            Case("an ID front taken upright", "national_id_front", 1200, 1900, 1),
            Case("an ID back taken upright", "national_id_back", 1200, 1900, 1),
            Case("a licence taken upright", "drivers_licence", 900, 1400, 1),
            Case("an ID already landscape", "national_id_front", 1900, 1200, 0),
            Case("a square crop is left alone", "drivers_licence", 1000, 1000, 0),
            Case("a logbook page stays portrait", "vehicle_logbook", 1200, 1900, 0),
            Case("a selfie stays as taken", "driver_selfie_liveness", 1200, 1600, 0),
        )
        val wrong = cases.filter { quarterTurnsLeft(it.type, it.width, it.height) != it.want }.map { "${it.name}: got ${quarterTurnsLeft(it.type, it.width, it.height)}, want ${it.want}" }
        assertEquals(emptyList<String>(), wrong)
    }
}
