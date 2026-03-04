package com.liddr.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.liddr.app.R

private val Manrope =
        FontFamily(
                Font(R.font.manrope_regular, FontWeight.Normal),
                Font(R.font.manrope_medium, FontWeight.Medium),
                Font(R.font.manrope_semibold, FontWeight.SemiBold),
                Font(R.font.manrope_bold, FontWeight.Bold),
                Font(R.font.manrope_extrabold, FontWeight.ExtraBold)
        )

val Typography =
        Typography(
                displayLarge =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.ExtraBold,
                                letterSpacing = (-0.01).sp
                        ),
                displayMedium =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.Bold,
                                letterSpacing = (-0.01).sp
                        ),
                displaySmall =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.Bold,
                                letterSpacing = (-0.01).sp
                        ),
                headlineLarge =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.Bold,
                                letterSpacing = (-0.01).sp
                        ),
                headlineMedium =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.SemiBold,
                                letterSpacing = (-0.01).sp
                        ),
                headlineSmall =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.SemiBold,
                                letterSpacing = (-0.01).sp
                        ),
                titleLarge =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.SemiBold,
                                letterSpacing = (-0.01).sp
                        ),
                titleMedium =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.Medium,
                                letterSpacing = (-0.01).sp
                        ),
                titleSmall =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.Medium,
                                letterSpacing = (-0.01).sp
                        ),
                bodyLarge =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.Normal,
                                fontSize = 16.sp,
                                lineHeight = 24.sp,
                                letterSpacing = 0.5.sp
                        ),
                bodyMedium = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Normal),
                bodySmall = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Normal),
                labelLarge =
                        TextStyle(
                                fontFamily = Manrope,
                                fontWeight = FontWeight.Medium,
                        ),
                labelMedium = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Medium),
                labelSmall = TextStyle(fontFamily = Manrope, fontWeight = FontWeight.Medium)
        )
