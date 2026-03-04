package com.liddr.app.ui.launch

import androidx.compose.ui.graphics.vector.ImageVector
import compose.icons.SimpleIcons
import compose.icons.TablerIcons
import compose.icons.simpleicons.Apple
import compose.icons.tablericons.BrandGoogle
import compose.icons.tablericons.Lock
import compose.icons.tablericons.Mail
import compose.icons.tablericons.Phone

data class AuthMethodUi(
        val method: String,
        val label: String,
        val icon: ImageVector,
        val allowedRoles: Set<AccountRoleUi> = AccountRoleUi.entries.toSet(),
        /** true → available when signing up */
        val signUp: Boolean = true,
        /** true → available when signing in */
        val signIn: Boolean = true
)

/** All methods defined once; filtering happens via [methodsForMode]. */
val allOnboardingMethods =
        listOf(
                AuthMethodUi(
                        method = "phone_otp",
                        label = "Phone number",
                        icon = TablerIcons.Phone,
                        signUp = false,
                        signIn = true
                ),
                AuthMethodUi(
                        method = "email_otp",
                        label = "Email",
                        icon = TablerIcons.Mail,
                        signUp = false,
                        signIn = true
                ),
                AuthMethodUi(
                        method = "email_password",
                        label = "Email & Password",
                        icon = TablerIcons.Lock
                ),
                AuthMethodUi(
                        method = "google",
                        label = "Google",
                        icon = TablerIcons.BrandGoogle,
                        allowedRoles = setOf(AccountRoleUi.RIDER)
                ),
                AuthMethodUi(
                        method = "apple",
                        label = "Apple",
                        icon = SimpleIcons.Apple,
                        allowedRoles = setOf(AccountRoleUi.RIDER)
                )
        )

/** Return only the methods available for a given [role] + [mode]. */
fun methodsForMode(role: AccountRoleUi, mode: AuthModeUi): List<AuthMethodUi> =
        allOnboardingMethods.filter { m ->
                role in m.allowedRoles && if (mode == AuthModeUi.SIGN_UP) m.signUp else m.signIn
        }
