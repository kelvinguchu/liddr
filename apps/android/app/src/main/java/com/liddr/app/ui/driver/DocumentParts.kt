package com.liddr.app.ui.driver

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.kit.Panel
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.SmallButton
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.theme.Status
import com.liddr.app.ui.theme.StatusColors
import compose.icons.TablerIcons
import compose.icons.tablericons.AlertCircle
import compose.icons.tablericons.CircleCheck
import compose.icons.tablericons.CircleDashed
import compose.icons.tablericons.Clock
import compose.icons.tablericons.Upload

// The pieces of "Your documents". Colour carries one meaning each, from the
// theme's status colours: teal is approved, amber is with Liddr, red needs the
// driver, and grey is only for what was never sent.

@Composable
private fun StatusTone.colors(): StatusColors = when (this) {
    StatusTone.DONE -> Status.done
    StatusTone.WAITING -> Status.waiting
    StatusTone.PROBLEM -> Status.problem
    StatusTone.IDLE -> Status.idle
}

/**
 * Where the driver stands: one line that says it, one that says what happens
 * next, and a bar with a segment for every document.
 */
@Composable
internal fun DocumentSummaryCard(summary: DocumentSummary, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val toDo = summary.toFix + summary.toSend
    Panel(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val (icon, tone) = when (summary.tone) {
                SummaryTone.TO_FIX -> TablerIcons.AlertCircle to StatusTone.PROBLEM
                SummaryTone.TO_SEND -> TablerIcons.Upload to StatusTone.IDLE
                SummaryTone.WAITING -> TablerIcons.Clock to StatusTone.WAITING
                SummaryTone.DONE -> TablerIcons.CircleCheck to StatusTone.DONE
            }
            val badge = tone.colors()
            Box(Modifier.size(Size.touch).clip(CircleShape).background(badge.wash), contentAlignment = Alignment.Center) {
                Icon(icon, null, Modifier.size(Size.icon), tint = if (tone == StatusTone.IDLE) colors.onSurface else badge.mark)
            }
            Spacer(Modifier.width(Space.md))
            Column(Modifier.weight(1f)) {
                Text(summary.headline, style = MaterialTheme.typography.titleLarge, color = colors.onSurface, modifier = Modifier.semantics { heading() })
                Text(summary.detail, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = Space.xs))
            }
        }
        Spacer(Modifier.height(Space.lg))
        val approved = Status.done.mark
        val waiting = Status.waiting.mark
        val problem = Status.problem.mark
        // Not sent is the pale wash: an empty slot in the bar, not a colour.
        val unsent = Status.idle.wash
        val segments = List(summary.approved) { approved } + List(summary.waiting) { waiting } + List(summary.toFix) { problem } + List(summary.toSend) { unsent }
        Column(Modifier.clearAndSetSemantics {
            contentDescription = "${summary.approved} of ${summary.total} approved, ${summary.waiting} in review, $toDo to do"
        }) {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.xs)) {
                segments.forEach { Box(Modifier.weight(1f).height(BarHeight).clip(CircleShape).background(it)) }
            }
            Spacer(Modifier.height(Space.md))
            Row(horizontalArrangement = Arrangement.spacedBy(Space.lg)) {
                Tally(summary.approved, "approved", approved)
                Tally(summary.waiting, "in review", waiting)
                Tally(toDo, "to do", if (summary.toFix > 0) problem else unsent)
            }
        }
    }
}

@Composable
private fun Tally(count: Int, label: String, color: Color) {
    val colors = MaterialTheme.colorScheme
    Row(verticalAlignment = Alignment.CenterVertically) {
        // The outline keeps the pale "not sent" dot visible on a pale card.
        Box(Modifier.size(Dot).clip(CircleShape).background(color).border(Hairline, colors.outline, CircleShape))
        Spacer(Modifier.width(Space.xs))
        Text("$count", style = MaterialTheme.typography.titleSmall, color = colors.onSurface)
        Spacer(Modifier.width(Space.xs))
        Text(label, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
    }
}

/**
 * One document: its name, a status mark, the Upload action when it is the
 * driver's move, and the reason underneath when it was turned down. [onOpen]
 * shows what was sent; it is null until there is something to show.
 */
@Composable
internal fun DocumentItem(row: DocumentRow, onUpload: () -> Unit, onOpen: (() -> Unit)? = null) {
    val colors = MaterialTheme.colorScheme
    val tappable = if (onOpen != null) Modifier.clickable(onClickLabel = "See what you sent", onClick = onOpen) else Modifier
    Column(Modifier.fillMaxWidth().then(tappable).padding(horizontal = Space.lg, vertical = Space.md)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(row.requirement.label, style = MaterialTheme.typography.titleMedium, color = colors.onSurface, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(Space.sm))
                StatusMark(row.stage)
            }
            if (row.stage.needsDriver) {
                Spacer(Modifier.width(Space.sm))
                SmallButton(if (row.stage == DocumentStage.MISSING) "Upload" else "Upload again", onUpload)
            } else if (onOpen != null) {
                RowChevron()
            }
        }
        row.note?.let { note ->
            Spacer(Modifier.height(Space.md))
            Text(
                note,
                style = MaterialTheme.typography.bodyMedium,
                color = colors.onSurface,
                modifier = Modifier.fillMaxWidth().clip(Corners.md).background(Status.problem.wash).padding(Space.md),
            )
        }
    }
}

/** A document's stage as a small tinted mark: an icon, or a spinner while something is moving, and two words. */
@Composable
internal fun StatusMark(stage: DocumentStage, modifier: Modifier = Modifier) {
    val tone = stage.tone.colors()
    val (fill, tint, text) = Triple(tone.wash, tone.mark, tone.ink)
    Row(
        modifier.clip(Corners.sm).background(fill).padding(horizontal = Space.sm, vertical = Space.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when (stage) {
            DocumentStage.UPLOADING, DocumentStage.CHECKING -> CircularProgressIndicator(Modifier.size(MarkSpinner), color = tint, strokeWidth = SpinnerStroke)
            DocumentStage.APPROVED -> Icon(TablerIcons.CircleCheck, null, Modifier.size(MarkIcon), tint = tint)
            DocumentStage.IN_REVIEW -> Icon(TablerIcons.Clock, null, Modifier.size(MarkIcon), tint = tint)
            DocumentStage.MISSING -> Icon(TablerIcons.CircleDashed, null, Modifier.size(MarkIcon), tint = tint)
            DocumentStage.REJECTED, DocumentStage.SEND_AGAIN, DocumentStage.EXPIRED -> Icon(TablerIcons.AlertCircle, null, Modifier.size(MarkIcon), tint = tint)
        }
        Spacer(Modifier.width(Space.xs))
        Text(stage.label, style = MaterialTheme.typography.labelLarge, color = text)
    }
}

private val BarHeight = 6.dp
private val Dot = 8.dp
private val Hairline = 1.dp
private val MarkIcon = 16.dp
private val MarkSpinner = 14.dp
private val SpinnerStroke = 2.dp
