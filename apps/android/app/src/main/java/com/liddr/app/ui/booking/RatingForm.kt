package com.liddr.app.ui.booking

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.liddr.app.ui.launch.AuthError
import com.liddr.app.ui.launch.AuthPrimaryButton

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
    error: String?,
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
        Text(prompt, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.onBackground)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            (1..5).forEach { star ->
                IconButton(onClick = { score = star }) {
                    Icon(
                        Icons.Filled.Star,
                        contentDescription = if (star == 1) "1 star" else "$star stars",
                        tint = if (star <= score) colors.primary else colors.outlineVariant,
                        modifier = Modifier.size(36.dp),
                    )
                }
            }
        }
        if (needsReason) {
            Spacer(Modifier.height(8.dp))
            Text("What went wrong?", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                reasons.forEach { (code, label) ->
                    FilterChip(
                        selected = code in chosen,
                        onClick = { chosen = if (code in chosen) chosen - code else chosen + code },
                        label = { Text(label) },
                    )
                }
            }
        }
        if (score > 0) {
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = comment,
                onValueChange = { comment = it.take(MAX_COMMENT) },
                placeholder = { Text("Add a comment (optional)") },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        AuthError(error)
        Spacer(Modifier.height(16.dp))
        AuthPrimaryButton("Submit rating", enabled = ready, busy = busy) { onSubmit(score, chosen, comment) }
        TextButton(onClick = onSkip, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("Skip") }
    }
}
