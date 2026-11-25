package com.liddr.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.liddr.app.R

/**
 * Figtree, the brand family, in five weights: smooth and open, so long reading stays
 * restful. Licensed under the SIL Open Font License; the licence ships in assets/licenses.
 */
private val Brand =
    FontFamily(
        Font(R.font.figtree_regular, FontWeight.Normal),
        Font(R.font.figtree_medium, FontWeight.Medium),
        Font(R.font.figtree_semibold, FontWeight.SemiBold),
        Font(R.font.figtree_bold, FontWeight.Bold),
        Font(R.font.figtree_extrabold, FontWeight.ExtraBold),
    )

/**
 * Number plates use Atkinson Hyperlegible Next, whose 1, I and l, 0 and O, 8 and B
 * cannot be mistaken for each other. Open Font License, in assets/licenses.
 */
private val Plate = FontFamily(Font(R.font.atkinson_hyperlegible_next_extrabold, FontWeight.ExtraBold))

/** A number plate, such as KMFB 123A. Riders match it on the street, so it is set for legibility. */
val PlateStyle = TextStyle(fontFamily = Plate, fontWeight = FontWeight.ExtraBold, fontSize = 20.sp, lineHeight = 26.sp, letterSpacing = 1.5.sp)

private fun style(weight: FontWeight, size: Int, line: Int, tracking: Double = 0.0) =
    TextStyle(fontFamily = Brand, fontWeight = weight, fontSize = size.sp, lineHeight = line.sp, letterSpacing = tracking.sp)

// Every style sets a size, and weight follows one ladder so the eye finds the
// heading first: Bold for screen headings, SemiBold for titles and buttons,
// Medium for small labels, Regular for everything you read. Only number
// plates (PlateStyle) go heavier.
val Typography =
    Typography(
        displayLarge = style(FontWeight.Bold, 48, 54, -1.0),
        displayMedium = style(FontWeight.Bold, 40, 46, -0.8),
        displaySmall = style(FontWeight.Bold, 34, 40, -0.6),
        headlineLarge = style(FontWeight.Bold, 30, 36, -0.5),
        headlineMedium = style(FontWeight.Bold, 26, 32, -0.4),
        headlineSmall = style(FontWeight.SemiBold, 22, 28, -0.2),
        titleLarge = style(FontWeight.SemiBold, 20, 26, -0.1),
        titleMedium = style(FontWeight.SemiBold, 16, 22),
        titleSmall = style(FontWeight.Medium, 14, 20),
        bodyLarge = style(FontWeight.Normal, 16, 24),
        bodyMedium = style(FontWeight.Normal, 14, 20),
        bodySmall = style(FontWeight.Normal, 12, 16, 0.1),
        labelLarge = style(FontWeight.Medium, 14, 20, 0.1),
        labelMedium = style(FontWeight.Medium, 12, 16, 0.3),
        labelSmall = style(FontWeight.Medium, 11, 16, 0.4),
    )
