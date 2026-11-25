package com.liddr.app.ui.account

import com.liddr.app.ui.kit.SegmentedControl
import com.liddr.app.ui.kit.RowDivider
import com.liddr.app.ui.kit.ListRow
import com.liddr.app.ui.kit.LiddrCard
import com.liddr.app.ui.kit.SectionHeader
import com.liddr.app.ui.kit.ScreenHeader
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Corners
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.kit.CircleButton
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.Overline
import com.liddr.app.ui.launch.displayDestination
import com.liddr.app.ui.theme.ThemeChoice
import com.liddr.app.ui.theme.ThemeSetting
import compose.icons.TablerIcons
import compose.icons.tablericons.ArrowsLeftRight
import compose.icons.tablericons.ChevronLeft
import compose.icons.tablericons.ChevronRight
import compose.icons.tablericons.Download
import compose.icons.tablericons.Logout
import compose.icons.tablericons.Trash
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Who you are, how the app looks, and what you can do with your account. */
@Composable
internal fun AccountScreen(
    state: AccountUiState,
    theme: ThemeSetting,
    onBack: () -> Unit,
    switchLabel: String?,
    onSwitch: () -> Unit,
    onSignOut: () -> Unit,
    onDelete: () -> Unit,
    onExport: () -> Unit,
    onExportSaved: (Boolean) -> Unit,
    onExportFailed: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val pending = state.export
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri == null || pending == null) {
            onExportSaved(false)
            return@rememberLauncherForActivityResult
        }
        scope.launch {
            val written = withContext(Dispatchers.IO) {
                runCatching { context.contentResolver.openOutputStream(uri)?.use { it.write(pending.toByteArray()) } != null }.getOrDefault(false)
            }
            if (written) onExportSaved(true) else onExportFailed()
        }
    }
    LaunchedEffect(pending) { if (pending != null) save.launch("liddr-data.json") }
    var confirmDelete by rememberSaveable { mutableStateOf(false) }
    val choice by theme.choice.collectAsState()
    val me = state.me ?: return

    Column(Modifier.fillMaxSize().background(colors.background).windowInsetsPadding(WindowInsets.safeDrawing)) {
        ScreenHeader("Account", onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Gutter)) {
            Spacer(Modifier.height(Space.sm))
            LiddrCard {
                val name = me.displayName.orEmpty()
                ListRow(
                    title = name.ifEmpty { "Your account" },
                    supporting = listOfNotNull(me.phone.takeIf(String::isNotEmpty)?.let(::displayDestination), roleNames(me.roles)).joinToString("\n"),
                    leading = {
                        Box(Modifier.size(Size.touch).clip(CircleShape).background(colors.secondaryContainer), contentAlignment = Alignment.Center) {
                            Text(name.firstOrNull()?.uppercase() ?: "?", style = MaterialTheme.typography.titleLarge, color = colors.onSecondaryContainer)
                        }
                    },
                )
            }

            SectionHeader("Appearance")
            SegmentedControl(ThemeChoice.entries.map { it.label }, ThemeChoice.entries.indexOf(choice), { theme.set(ThemeChoice.entries[it]) })

            SectionHeader("Your account")
            LiddrCard {
                if (switchLabel != null) {
                    ListRow(switchLabel, onClick = onSwitch, leading = { RowIcon(TablerIcons.ArrowsLeftRight) }, trailing = { Chevron() })
                    RowDivider()
                }
                ListRow(
                    "Download my data",
                    supporting = "A copy of everything Liddr holds about you",
                    onClick = onExport.takeUnless { state.busy },
                    leading = { RowIcon(TablerIcons.Download) },
                    trailing = { Chevron() },
                )
                RowDivider()
                ListRow("Sign out", onClick = onSignOut.takeUnless { state.busy }, leading = { RowIcon(TablerIcons.Logout) }, trailing = { Chevron() })
            }

            Spacer(Modifier.height(Space.xxl))
            LiddrCard {
                ListRow(
                    "Delete account",
                    supporting = "Removes your name, phone number and email",
                    titleColor = colors.error,
                    onClick = { confirmDelete = true }.takeUnless { state.busy },
                    leading = { RowIcon(TablerIcons.Trash, colors.error) },
                )
            }
            Spacer(Modifier.height(Space.xl))
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            containerColor = colors.surface,
            title = { Text("Delete your account?") },
            text = { Text("Your name, phone number and email are removed straight away. Trip and payment records are kept without them, as the law requires. This can't be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    onDelete()
                }) { Text("Delete", color = colors.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Keep account") } },
        )
    }
}

@Composable
private fun RowIcon(icon: ImageVector, tint: Color = MaterialTheme.colorScheme.onSurface) {
    Icon(icon, null, Modifier.size(Size.icon), tint = tint)
}

@Composable
private fun Chevron() {
    Icon(TablerIcons.ChevronRight, null, Modifier.size(Size.smallIcon), tint = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Roles as people say them: "ops" is staff. */
private fun roleNames(roles: List<String>): String? = roles.map {
    when (it) {
        "ops", "admin" -> "Staff"
        else -> it.replaceFirstChar(Char::uppercase)
    }
}.distinct().joinToString(" · ").takeIf(String::isNotEmpty)
