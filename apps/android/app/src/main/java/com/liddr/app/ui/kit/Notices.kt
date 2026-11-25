package com.liddr.app.ui.kit

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalAccessibilityManager
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import compose.icons.TablerIcons
import compose.icons.tablericons.AlertCircle
import compose.icons.tablericons.CircleCheck
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * A short message about something that happened away from the screen's fields:
 * usually a failure, or with [done] a finished background task such as a saved file.
 */
class Notice(val message: String, val actionLabel: String? = null, val action: (() -> Unit)? = null, val done: Boolean = false)

/**
 * The app's one message bar. Background failures, such as booking again or
 * cancelling, go here. A problem with a field stays under the field, and a list
 * with nothing to show says why in its own place. A newer notice replaces an
 * older one, so they never pile up.
 */
class Notices {
    private val _current = MutableStateFlow<Notice?>(null)
    val current: StateFlow<Notice?> = _current.asStateFlow()

    fun show(message: String, actionLabel: String? = null, action: (() -> Unit)? = null) {
        _current.value = Notice(message, actionLabel, action)
    }

    /** Confirms something that finished out of sight, such as a file saved by another app. */
    fun done(message: String) {
        _current.value = Notice(message, done = true)
    }

    /** Hides [notice] if it is still the one showing, so an old timer never hides a newer one. */
    fun dismiss(notice: Notice) {
        _current.compareAndSet(notice, null)
    }
}

/** Shows the current notice at the top of the screen, clear of sheets, docks and the keyboard. */
@Composable
fun NoticeHost(notices: Notices, modifier: Modifier = Modifier) {
    val notice by notices.current.collectAsState()
    // Kept while the bar slides away, so its text doesn't vanish first.
    var last by remember { mutableStateOf<Notice?>(null) }
    val accessibility = LocalAccessibilityManager.current
    LaunchedEffect(notice) {
        val shown = notice ?: return@LaunchedEffect
        last = shown
        val base = if (shown.action != null) WITH_ACTION_MS else PLAIN_MS
        // People using a screen reader or longer timeouts get the time their phone asks for.
        delay(accessibility?.calculateRecommendedTimeoutMillis(base, containsIcons = true, containsText = true, containsControls = shown.action != null) ?: base)
        notices.dismiss(shown)
    }
    AnimatedVisibility(
        visible = notice != null,
        enter = slideInVertically { -it } + fadeIn(),
        exit = slideOutVertically { -it } + fadeOut(),
        modifier = modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = Gutter, vertical = Space.sm),
    ) {
        (notice ?: last)?.let { shown -> NoticeBar(shown, onDismiss = { notices.dismiss(shown) }) }
    }
}

@Composable
private fun NoticeBar(notice: Notice, onDismiss: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(
        onClick = onDismiss,
        shape = Corners.lg,
        color = colors.inverseSurface,
        contentColor = colors.inverseOnSurface,
        shadowElevation = BarShadow,
        modifier = Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite },
    ) {
        Row(
            Modifier.heightIn(min = Size.control).padding(start = Space.lg, end = if (notice.action != null) Space.xs else Space.lg, top = Space.sm, bottom = Space.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(if (notice.done) TablerIcons.CircleCheck else TablerIcons.AlertCircle, null, Modifier.size(Size.smallIcon))
            Spacer(Modifier.width(Space.md))
            Text(notice.message, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            val action = notice.action
            if (notice.actionLabel != null && action != null) {
                LinkButton(notice.actionLabel, {
                    onDismiss()
                    action()
                }, color = colors.inversePrimary)
            }
        }
    }
}

private const val PLAIN_MS = 4_000L
private const val WITH_ACTION_MS = 8_000L
private val BarShadow = 6.dp
