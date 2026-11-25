package com.liddr.app.ui.driver

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import com.liddr.app.ui.booking.SheetTitle
import com.liddr.app.ui.driver.capture.CaptureKind
import com.liddr.app.ui.driver.capture.CaptureScreen
import com.liddr.app.ui.driver.capture.captureSpec
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.LiddrCard
import com.liddr.app.ui.kit.ListRow
import com.liddr.app.ui.kit.RowDivider
import com.liddr.app.ui.kit.SectionHeader
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Space
import compose.icons.TablerIcons
import compose.icons.tablericons.Camera
import compose.icons.tablericons.File as FileIcon
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.launch

private const val YEAR_MS = 365L * 24 * 60 * 60 * 1000

/**
 * The driver's verification documents: where they stand, what needs them
 * first, and the way to send each one. The view model refreshes the list while
 * this screen is up, so a decision by staff shows without leaving it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DocumentsScreen(state: DriverUiState, viewModel: DriverViewModel, onAccount: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val requirements = state.verification?.requirements.orEmpty()
    var choosing by rememberSaveable { mutableStateOf<String?>(null) }
    var askExpiry by rememberSaveable { mutableStateOf(false) }
    var expiresOn by rememberSaveable { mutableStateOf<String?>(null) }
    var showSource by rememberSaveable { mutableStateOf(false) }
    // The document type Liddr's camera is open for.
    var capturing by rememberSaveable { mutableStateOf<String?>(null) }
    // The document type whose sent file is showing in the drawer.
    var viewing by rememberSaveable { mutableStateOf<String?>(null) }

    fun send(uri: Uri) {
        val type = choosing ?: return
        val expiry = expiresOn
        scope.launch {
            val file = readDocument(context, uri, type)
            if (file == null) viewModel.reportError("We couldn't read that file. Please try another.") else viewModel.upload(type, file.contentType, file.bytes, expiry)
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> uri?.let(::send) }
    fun specOf(type: String) = captureSpec(type, requirements.firstOrNull { it.documentType == type }?.label.orEmpty())
    // A document can be scanned or sent as a file, so it gets the choice. A vehicle photo or selfie goes straight to the camera.
    fun chooseSource(type: String) {
        if (specOf(type).kind == CaptureKind.DOCUMENT) showSource = true else capturing = type
    }

    capturing?.let { type ->
        val spec = specOf(type)
        CaptureScreen(
            spec = spec,
            onUse = { jpeg ->
                capturing = null
                viewModel.upload(type, "image/jpeg", jpeg, expiresOn)
            },
            onChooseFile = {
                capturing = null
                picker.launch(if (spec.kind == CaptureKind.DOCUMENT) "*/*" else "image/*")
            },
            onClose = { capturing = null },
        )
        return
    }
    val rows = documentRows(requirements, state.uploading)
    val summary = summarise(rows)
    fun startUpload(row: DocumentRow) {
        // One file at a time, so a slow upload is never overtaken by the next.
        if (state.uploading != null) return
        choosing = row.requirement.documentType
        expiresOn = null
        if (row.requirement.requiresExpiry) askExpiry = true else chooseSource(row.requirement.documentType)
    }

    DriverPage(title = "Your documents", onAccount = onAccount, body = "We're getting your list ready.".takeIf { rows.isEmpty() }) {
        Spacer(Modifier.height(Space.xl))
        if (summary.total > 0) DocumentSummaryCard(summary)
        documentGroups(rows).forEach { (group, members) ->
            SectionHeader(group.title)
            LiddrCard {
                members.forEachIndexed { index, row ->
                    if (index > 0) RowDivider(inset = false)
                    DocumentItem(
                        row,
                        onUpload = { startUpload(row) },
                        onOpen = { viewing = row.requirement.documentType }.takeIf { row.requirement.document != null && row.stage != DocumentStage.UPLOADING },
                    )
                }
            }
        }
    }

    viewing?.let { type ->
        rows.firstOrNull { it.requirement.documentType == type }?.let { row ->
            DocumentSheet(
                row,
                open = viewModel::openDocument,
                onUpload = {
                    viewing = null
                    startUpload(row)
                },
                onDismiss = { viewing = null },
            )
        }
    }

    if (askExpiry) {
        val now = System.currentTimeMillis()
        val picked = rememberDatePickerState(
            initialSelectedDateMillis = now + YEAR_MS,
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long) = utcTimeMillis > now
            },
        )
        DatePickerDialog(
            onDismissRequest = { askExpiry = false },
            confirmButton = {
                TextButton(onClick = {
                    expiresOn = picked.selectedDateMillis?.let { millis ->
                        SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(millis))
                    }
                    askExpiry = false
                    choosing?.let(::chooseSource)
                }) { Text("Next") }
            },
            dismissButton = { TextButton(onClick = { askExpiry = false }) { Text("Cancel") } },
        ) { DatePicker(state = picked, title = { Text("When does it expire?", Modifier.padding(start = Space.xl, top = Space.lg)) }) }
    }

    if (showSource) {
        ModalBottomSheet(onDismissRequest = { showSource = false }, containerColor = MaterialTheme.colorScheme.surface, shape = Corners.sheet) {
            Column(Modifier.navigationBarsPadding().padding(bottom = Space.lg)) {
                Column(Modifier.padding(horizontal = Gutter)) {
                    SheetTitle("Add this document", "Scanning finds the edges and straightens the page for you.")
                }
                Spacer(Modifier.height(Space.sm))
                SourceRow(TablerIcons.Camera, "Scan with camera") {
                    showSource = false
                    capturing = choosing
                }
                RowDivider(inset = false)
                SourceRow(TablerIcons.FileIcon, "Choose a file") {
                    showSource = false
                    picker.launch("*/*")
                }
            }
        }
    }
}

@Composable
private fun SourceRow(icon: ImageVector, label: String, onClick: () -> Unit) {
    ListRow(label, onClick = onClick, leading = { Icon(icon, null, Modifier.size(Size.icon), tint = MaterialTheme.colorScheme.onSurface) }, trailing = { RowChevron() })
}

