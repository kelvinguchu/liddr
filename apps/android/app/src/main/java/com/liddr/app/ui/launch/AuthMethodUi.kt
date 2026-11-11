package com.liddr.app.ui.launch

import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.KeyboardType
import compose.icons.TablerIcons
import compose.icons.tablericons.Mail
import compose.icons.tablericons.Phone

data class AuthMethodUi(
    val method: String,
    val label: String,
    val icon: ImageVector,
    val prompt: String,
    val hint: String,
    val keyboard: KeyboardType,
    val isValid: (String) -> Boolean,
    val allowedRoles: Set<AccountRoleUi> = AccountRoleUi.entries.toSet(),
)

private val kenyanMobile = Regex("""^(\+?254|0)?[17]\d{8}$""")
private val emailShape = Regex("""^[^@\s]+@[^@\s]+\.[^@\s]+$""")

/** The sign-in methods the API supports. A code creates the account if it is new. */
val allOnboardingMethods = listOf(
    AuthMethodUi(
        method = "phone_otp",
        label = "Phone number",
        icon = TablerIcons.Phone,
        prompt = "We'll text you a 6-digit code.",
        hint = "0712 345 678",
        keyboard = KeyboardType.Phone,
        isValid = { kenyanMobile.matches(it.filterNot { c -> c == ' ' || c == '-' }) },
    ),
    AuthMethodUi(
        method = "email_otp",
        label = "Email",
        icon = TablerIcons.Mail,
        prompt = "We'll email you a 6-digit code.",
        hint = "you@example.com",
        keyboard = KeyboardType.Email,
        isValid = { emailShape.matches(it.trim()) },
        allowedRoles = setOf(AccountRoleUi.RIDER),
    ),
)
