package com.liddr.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.liddr.app.R

/**
 * Plus Jakarta Sans, the one brand family, in five weights. Licensed under the SIL
 * Open Font License; the licence ships in assets/licenses.
 */
private val Brand =
    FontFamily(
        Font(R.font.plus_jakarta_sans_regular, FontWeight.Normal),
        Font(R.font.plus_jakarta_sans_medium, FontWeight.Medium),
        Font(R.font.plus_jakarta_sans_semibold, FontWeight.SemiBold),
        Font(R.font.plus_jakarta_sans_bold, FontWeight.Bold),
        Font(R.font.plus_jakarta_sans_extrabold, FontWeight.ExtraBold),
    )

private fun style(weight: FontWeight, size: Int, line: Int, tracking: Double = 0.0) =
    TextStyle(fontFamily = Brand, fontWeight = weight, fontSize = size.sp, lineHeight = line.sp, letterSpacing = tracking.sp)

// Every style sets a size. Headings tighten their tracking; body text stays open for small screens.
val Typography =
    Typography(
        displayLarge = style(FontWeight.ExtraBold, 48, 54, -1.0),
        displayMedium = style(FontWeight.ExtraBold, 40, 46, -0.8),
        displaySmall = style(FontWeight.ExtraBold, 34, 40, -0.6),
        headlineLarge = style(FontWeight.ExtraBold, 30, 36, -0.6),
        headlineMedium = style(FontWeight.ExtraBold, 26, 32, -0.5),
        headlineSmall = style(FontWeight.Bold, 22, 28, -0.3),
        titleLarge = style(FontWeight.Bold, 20, 26, -0.2),
        titleMedium = style(FontWeight.SemiBold, 16, 22),
        titleSmall = style(FontWeight.SemiBold, 14, 20),
        bodyLarge = style(FontWeight.Normal, 16, 24),
        bodyMedium = style(FontWeight.Normal, 14, 20),
        bodySmall = style(FontWeight.Normal, 12, 16, 0.1),
        labelLarge = style(FontWeight.SemiBold, 14, 20, 0.1),
        labelMedium = style(FontWeight.SemiBold, 12, 16, 0.3),
        labelSmall = style(FontWeight.SemiBold, 11, 16, 0.4),
    )
