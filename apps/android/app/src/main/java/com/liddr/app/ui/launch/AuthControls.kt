package com.liddr.app.ui.launch

import com.liddr.app.ui.kit.PrimaryButton
import com.liddr.app.ui.kit.Size
import com.liddr.app.ui.kit.Space
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** An error the API or the network gave. Screen readers announce it. */
@Composable
fun AuthError(message: String?) {
    if (message == null) return
    Text(
        message,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.error,
        modifier = Modifier.padding(top = Space.sm).semantics { liveRegion = LiveRegionMode.Polite },
    )
}

@Composable
fun AuthProgress(modifier: Modifier = Modifier) {
    CircularProgressIndicator(modifier.size(Size.icon), strokeWidth = SpinnerStroke, color = MaterialTheme.colorScheme.secondary)
}

@Composable
fun AuthPrimaryButton(label: String, enabled: Boolean, busy: Boolean, onClick: () -> Unit) {
    // Kept for screens not yet rebuilt on the kit; it is the kit's button.
    PrimaryButton(label, onClick = onClick, enabled = enabled, busy = busy)
}

private val SpinnerStroke = 2.5.dp
