package com.liddr.app.ui.driver

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.liddr.app.data.OfflineException
import com.liddr.app.data.ProblemException
import com.liddr.app.ui.booking.SheetTitle
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.kit.Gutter
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.RowDivider
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.theme.Status
import compose.icons.TablerIcons
import compose.icons.tablericons.Clock
import compose.icons.tablericons.FileOff

/** What the drawer can show of the file itself. */
private sealed interface Preview {
    data object Loading : Preview

    /** The server is still scanning it, so it can't be opened yet. */
    data object Checking : Preview

    data object Failed : Preview

    data class Ready(val picture: Bitmap) : Preview
}

/**
 * What the driver sent for one document: the file itself, where it stands, and
 * when it was sent. The file is fetched through a five-minute link and kept in
 * memory only, so closing the drawer is the end of it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DocumentSheet(row: DocumentRow, open: suspend (String) -> ByteArray, onUpload: () -> Unit, onDismiss: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val context = LocalContext.current
    val document = row.requirement.document ?: return
    var preview by remember(document.id) { mutableStateOf<Preview>(Preview.Loading) }
    var attempt by remember { mutableIntStateOf(0) }

    LaunchedEffect(document.id, row.stage, attempt) {
        val id = document.id
        preview = when {
            row.stage == DocumentStage.CHECKING -> Preview.Checking
            id == null -> Preview.Failed
            else -> try {
                previewOf(context, open(id), row.requirement.documentType)?.let(Preview::Ready) ?: Preview.Failed
            } catch (e: ProblemException) {
                // 409: the file hasn't passed its safety scan, or failed it.
                if (e.status == CONFLICT && !row.stage.isProblem) Preview.Checking else Preview.Failed
            } catch (_: OfflineException) {
                Preview.Failed
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = colors.surface,
        shape = Corners.sheet,
    ) {
        Column(Modifier.navigationBarsPadding().verticalScroll(rememberScrollState()).padding(start = Gutter, end = Gutter, bottom = Space.lg)) {
            SheetTitle(row.requirement.label)
            Spacer(Modifier.height(Space.sm))
            StatusMark(row.stage)
            Spacer(Modifier.height(Space.lg))
            FilePreview(preview, onRetry = { attempt++ })
            row.note?.let { note ->
                Spacer(Modifier.height(Space.lg))
                Text(
                    note,
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.onSurface,
                    modifier = Modifier.fillMaxWidth().clip(Corners.md).background(Status.problem.wash).padding(Space.md),
                )
            }
            val facts = documentFacts(document)
            if (facts.isNotEmpty()) {
                Spacer(Modifier.height(Space.md))
                facts.forEachIndexed { index, (label, value) ->
                    if (index > 0) RowDivider(inset = false)
                    Row(Modifier.fillMaxWidth().padding(vertical = Space.md), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(label, style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
                        Text(value, style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
                    }
                }
            }
            if (row.stage.needsDriver) {
                Spacer(Modifier.height(Space.lg))
                PrimaryButton("Upload again", onUpload)
            }
        }
    }
}

@Composable
private fun FilePreview(preview: Preview, onRetry: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val frame = Modifier.fillMaxWidth().clip(Corners.lg).background(colors.surfaceContainerHigh)
    when (preview) {
        is Preview.Ready -> Box(frame, contentAlignment = Alignment.Center) {
            val picture = preview.picture
            Image(
                picture.asImageBitmap(),
                "The file you sent",
                contentScale = ContentScale.Fit,
                modifier = Modifier.heightIn(max = PreviewHeight).aspectRatio(picture.width.toFloat() / picture.height),
            )
        }
        Preview.Loading -> Box(frame.height(PreviewHeight), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(Modifier.size(Size.icon), color = colors.onSurfaceVariant, strokeWidth = SpinnerStroke)
        }
        Preview.Checking -> PreviewMessage(frame, TablerIcons.Clock, "We're checking this file. You can see it here once that's done.")
        Preview.Failed -> PreviewMessage(frame, TablerIcons.FileOff, "We couldn't show this file.") {
            LinkButton("Try again", onRetry)
        }
    }
}

@Composable
private fun PreviewMessage(frame: Modifier, icon: ImageVector, text: String, action: @Composable () -> Unit = {}) {
    val colors = MaterialTheme.colorScheme
    Column(frame.height(PreviewHeight).padding(Space.xl), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(icon, null, Modifier.size(Size.icon), tint = colors.onSurfaceVariant)
        Spacer(Modifier.height(Space.sm))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, textAlign = TextAlign.Center)
        action()
    }
}

private const val CONFLICT = 409
private val PreviewHeight = 320.dp
private val SpinnerStroke = 2.dp
