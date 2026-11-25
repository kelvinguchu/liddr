package com.liddr.app.ui.driver.capture

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.liddr.app.ui.kit.EmptyState
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.theme.LiddrTheme
import compose.icons.TablerIcons
import compose.icons.tablericons.Camera

/**
 * Liddr's own camera for one verification file: ask for the camera, take the
 * photo with guidance, then review it. [onUse] receives a JPEG ready to upload,
 * with nothing the camera wrote about the place or the phone left in it.
 *
 * Back goes from the review to the camera, and from the camera to the caller.
 * [onChooseFile] is the way out for a phone whose camera cannot be used.
 */
@Composable
fun CaptureScreen(spec: CaptureSpec, onUse: (ByteArray) -> Unit, onChooseFile: (() -> Unit)?, onClose: () -> Unit) {
    val context = LocalContext.current
    var allowed by remember { mutableStateOf(cameraAllowed(context)) }
    // The photo lives only in memory. If Android clears the app away, the camera simply opens again.
    var shot by remember { mutableStateOf<Shot?>(null) }
    BackHandler { if (shot != null) shot = null else onClose() }
    // Cameras are dark so the picture is the brightest thing on screen, whatever theme the app is in.
    LiddrTheme(darkTheme = true) {
        NightSystemBars()
        val taken = shot
        when {
            !allowed -> PermissionStage(spec, onAllowed = { allowed = true }, onChooseFile = onChooseFile, onClose = onClose)
            taken == null -> LiveStage(spec, onShot = { shot = it }, onChooseFile = onChooseFile, onClose = onClose)
            else -> ReviewStage(spec, taken, onRetake = { shot = null }, onUse = onUse, onClose = onClose)
        }
    }
}

private fun cameraAllowed(context: Context) =
    ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

private tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/**
 * Asks for the camera once on arrival. If the driver says no, it explains why
 * Liddr asks and offers to ask again; once Android will no longer ask, the
 * button opens Liddr's page in Settings, and the camera starts on return.
 */
@Composable
private fun PermissionStage(spec: CaptureSpec, onAllowed: () -> Unit, onChooseFile: (() -> Unit)?, onClose: () -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var asked by rememberSaveable { mutableStateOf(false) }
    var blocked by rememberSaveable { mutableStateOf(false) }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            onAllowed()
        } else {
            // After a refusal, Android offering no explanation means it will not show its dialog again.
            blocked = context.activity()?.let { !ActivityCompat.shouldShowRequestPermissionRationale(it, Manifest.permission.CAMERA) } ?: true
        }
    }
    LaunchedEffect(Unit) {
        if (!asked) {
            asked = true
            request.launch(Manifest.permission.CAMERA)
        }
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && cameraAllowed(context)) onAllowed()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    val selfie = spec.kind == CaptureKind.SELFIE
    CaptureFrame(
        title = spec.title,
        onClose = onClose,
        hint = "",
        picture = {
            EmptyState(
                TablerIcons.Camera,
                "Let Liddr use your camera",
                when {
                    blocked -> "Camera access is turned off for Liddr. Turn it on in Settings, under Permissions."
                    selfie -> "Liddr uses the camera only to take your selfie. Nothing is sent until you choose to send it."
                    else -> "Liddr uses the camera only to photograph this for your verification. Nothing is sent until you choose to send it."
                },
                Modifier.align(Alignment.Center),
                actionLabel = if (blocked) "Open Settings" else "Allow camera",
                onAction = { if (blocked) openAppSettings(context) else request.launch(Manifest.permission.CAMERA) },
            )
        },
        controls = {
            // A selfie has to be taken here; a document or vehicle photo can come from a file.
            if (onChooseFile != null && !selfie) LinkButton("Choose a file instead", onChooseFile, color = MaterialTheme.colorScheme.onBackground)
        },
    )
}

private fun openAppSettings(context: Context) {
    val page = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
        context.startActivity(page)
    } catch (_: ActivityNotFoundException) {
        // A phone with no page for one app: its main Settings screen still leads there.
        context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

/** Light icons on the status and navigation bars while the dark camera is up, then back as they were. */
@Composable
private fun NightSystemBars() {
    val view = LocalView.current
    DisposableEffect(view) {
        val bars = view.context.activity()?.window?.let { WindowCompat.getInsetsController(it, view) }
        val lightStatus = bars?.isAppearanceLightStatusBars
        val lightNavigation = bars?.isAppearanceLightNavigationBars
        bars?.isAppearanceLightStatusBars = false
        bars?.isAppearanceLightNavigationBars = false
        onDispose {
            if (bars != null && lightStatus != null && lightNavigation != null) {
                bars.isAppearanceLightStatusBars = lightStatus
                bars.isAppearanceLightNavigationBars = lightNavigation
            }
        }
    }
}
