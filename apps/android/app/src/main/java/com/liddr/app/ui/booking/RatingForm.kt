package com.liddr.app.ui.booking

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.kit.Corners
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Space
import com.liddr.app.ui.launch.AuthError

private const val MAX_COMMENT = 200

/** Reason codes the API records. Traffic, app and pickup problems don't count against the driver. */
private val driverReasons = listOf(
    "late" to "Arrived late",
    "unsafe_driving" to "Unsafe driving",
    "rude" to "Rude",
    "vehicle_condition" to "Vehicle condition",
    "long_route" to "Took a long route",
    "traffic" to "Traffic",
    "app_issue" to "App problem",
    "wrong_pickup_pin" to "Wrong pickup point",
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun RatingForm(
    busy: Boolean,
    error: String? = null,
    prompt: String = "Rate your driver",
    reasons: List<Pair<String, String>> = driverReasons,
    onSubmit: (Int, List<String>, String) -> Unit,
    onSkip: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    var score by rememberSaveable { mutableIntStateOf(0) }
    var chosen by rememberSaveable { mutableStateOf(listOf<String>()) }
    var comment by rememberSaveable { mutableStateOf("") }
    val needsReason = score in 1..4
    val ready = score > 0 && (!needsReason || chosen.isNotEmpty()) && !busy

    Column {
        Text(prompt, style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
        Row(Modifier.fillMaxWidth().padding(top = Space.xs), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            (1..5).forEach { star ->
                IconButton(onClick = { score = star }, modifier = Modifier.size(StarTarget)) {
                    Icon(
                        Icons.Filled.Star,
                        contentDescription = if (star == 1) "1 star" else "$star stars",
                        tint = if (star <= score) colors.secondary else colors.surfaceContainerHigh,
                        modifier = Modifier.size(StarSize),
                    )
                }
            }
        }
        Text(scoreWords(score), style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant, modifier = Modifier.align(Alignment.CenterHorizontally))
        if (needsReason) {
            Text("What went wrong?", style = MaterialTheme.typography.titleSmall, color = colors.onSurface, modifier = Modifier.padding(top = Space.lg, bottom = Space.sm))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.sm), verticalArrangement = Arrangement.spacedBy(Space.sm)) {
                reasons.forEach { (code, label) ->
                    ReasonChip(label, code in chosen) { chosen = if (code in chosen) chosen - code else chosen + code }
                }
            }
        }
        if (score > 0) {
            OutlinedTextField(
                value = comment,
                onValueChange = { comment = it.take(MAX_COMMENT) },
                placeholder = { Text("Add a comment (optional)", style = MaterialTheme.typography.bodyLarge) },
                textStyle = MaterialTheme.typography.bodyLarge,
                shape = Corners.lg,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.secondary,
                    unfocusedBorderColor = colors.outlineVariant,
                    cursorColor = colors.secondary,
                ),
                modifier = Modifier.fillMaxWidth().padding(top = Space.lg),
            )
        }
        AuthError(error)
        Spacer(Modifier.height(Space.lg))
        PrimaryButton("Submit rating", onClick = { onSubmit(score, chosen, comment) }, enabled = ready, busy = busy)
        Spacer(Modifier.height(Space.xs))
        LinkButton("Skip for now", { if (!busy) onSkip() }, Modifier.align(Alignment.CenterHorizontally), color = colors.onSurfaceVariant)
    }
}

@Composable
private fun ReasonChip(label: String, picked: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(
        onClick = onClick,
        shape = Corners.sm,
        color = if (picked) colors.primaryContainer else colors.surfaceContainerLow,
        border = BorderStroke(ChipBorder, if (picked) colors.secondary else colors.outlineVariant),
        modifier = Modifier.height(Size.chip).semantics {
            role = Role.Checkbox
            selected = picked
        },
    ) {
        Box(Modifier.padding(horizontal = Space.md), contentAlignment = Alignment.Center) {
            Text(label, style = MaterialTheme.typography.labelLarge, color = if (picked) colors.onPrimaryContainer else colors.onSurface)
        }
    }
}

/** A word for the stars picked, so the score reads without counting. */
private fun scoreWords(score: Int) = when (score) {
    1 -> "Terrible"
    2 -> "Bad"
    3 -> "Okay"
    4 -> "Good"
    5 -> "Great"
    else -> "Tap a star"
}

private val StarSize = 40.dp
private val StarTarget = 56.dp
private val ChipBorder = 1.dp
