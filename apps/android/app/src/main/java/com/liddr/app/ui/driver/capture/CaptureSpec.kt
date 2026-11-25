package com.liddr.app.ui.driver.capture

/** How a verification file is photographed. */
enum class CaptureKind {
    /** A flat document: found, outlined, straightened and cleaned. */
    DOCUMENT,

    /** A photo of the vehicle, kept as taken. */
    PHOTO,

    /** The driver's own face, with the front camera. */
    SELFIE,
}

/** What the camera needs to know about one file: how to take it, its name, and which document it is. */
data class CaptureSpec(val kind: CaptureKind, val title: String, val documentType: String = "")

/** The camera set-up for a document type from the verification list. [label] is its name there. */
fun captureSpec(documentType: String, label: String): CaptureSpec = when (documentType) {
    "driver_selfie_liveness" -> CaptureSpec(CaptureKind.SELFIE, "Your selfie", documentType)
    "vehicle_photo_front", "vehicle_photo_back", "vehicle_photo_side" -> CaptureSpec(CaptureKind.PHOTO, label, documentType)
    else -> CaptureSpec(CaptureKind.DOCUMENT, label, documentType)
}

/** ID cards and driving licences are landscape cards, whichever way the photo was taken. */
fun isLandscapeCard(documentType: String): Boolean = documentType in LANDSCAPE_CARDS

private val LANDSCAPE_CARDS = setOf("national_id_front", "national_id_back", "drivers_licence")

/**
 * How many quarter turns to the left a picture of [documentType] needs to show
 * the right way up: a landscape card that came out portrait turns once.
 */
fun quarterTurnsLeft(documentType: String, width: Int, height: Int): Int = if (isLandscapeCard(documentType) && height > width) 1 else 0
