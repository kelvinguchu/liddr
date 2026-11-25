package com.liddr.app.ui.driver.capture

import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.liddr.app.ui.kit.CircleButton
import com.liddr.app.ui.kit.EmptyState
import com.liddr.app.ui.kit.LinkButton
import com.liddr.app.ui.launch.AuthProgress
import compose.icons.TablerIcons
import compose.icons.tablericons.Bolt
import compose.icons.tablericons.BoltOff
import compose.icons.tablericons.CameraOff
import compose.icons.tablericons.Photo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private enum class CameraStatus { STARTING, READY, UNAVAILABLE }

// How long the selfie waits for the face finder before letting the driver take
// the photo anyway. The platform finder misses some faces in poor light, and
// staff look at every selfie, so a miss must not leave the driver stuck.
private const val SELFIE_PATIENCE_MS = 8_000L

/** The live camera. Leaving it, by a photo, Close or Back, closes the camera. */
@Composable
internal fun LiveStage(spec: CaptureSpec, onShot: (Shot) -> Unit, onChooseFile: (() -> Unit)?, onClose: () -> Unit) {
    // "Try again" opens a fresh camera rather than reviving a failed one.
    var attempt by remember { mutableIntStateOf(0) }
    key(attempt) { LiveCamera(spec, onShot, onChooseFile, onClose, onRetry = { attempt++ }) }
}

@Composable
private fun LiveCamera(spec: CaptureSpec, onShot: (Shot) -> Unit, onChooseFile: (() -> Unit)?, onClose: () -> Unit, onRetry: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()
    val view = LocalView.current
    val haptics = LocalHapticFeedback.current
    val selfie = spec.kind == CaptureKind.SELFIE
    val session = remember { CameraSession(context.applicationContext, spec.kind) }
    val viewfinder = remember {
        PreviewView(context).apply {
            // Drawn as a texture so the picture can have rounded corners and marks over it.
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }
    var status by remember { mutableStateOf(CameraStatus.STARTING) }
    var hasLight by remember { mutableStateOf(false) }
    var shooting by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    var patient by remember { mutableStateOf(false) }
    val reading by session.reading.collectAsState()
    val lightOn by session.torchOn.collectAsState()

    DisposableEffect(session) {
        // Lining up a document takes longer than a screen timeout; the flag goes when the camera does.
        view.keepScreenOn = true
        onDispose {
            view.keepScreenOn = false
            session.close()
        }
    }
    LaunchedEffect(session) {
        status = try {
            hasLight = session.start(owner, viewfinder.surfaceProvider)
            CameraStatus.READY
        } catch (_: CameraFailure) {
            CameraStatus.UNAVAILABLE
        }
    }
    if (selfie) LaunchedEffect(session) {
        delay(SELFIE_PATIENCE_MS)
        patient = true
    }

    fun shoot() {
        if (shooting || status != CameraStatus.READY) return
        shooting = true
        problem = null
        // A tap the hand can feel, since an automatic shot gives no other sign before the review.
        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        val lastSeen = reading.quad
        scope.launch {
            try {
                val bitmap = session.shoot()
                onShot(withContext(Dispatchers.Default) { shotOf(bitmap, spec.kind, lastSeen) })
            } catch (_: CameraFailure) {
                problem = "Didn't save. Try again"
                shooting = false
            }
        }
    }
    // A shot held ready for long enough takes itself.
    val held = reading.progress >= 1f
    LaunchedEffect(held) { if (held) shoot() }

    val unavailable = status == CameraStatus.UNAVAILABLE
    CaptureFrame(
        title = spec.title,
        onClose = onClose,
        hint = when {
            unavailable -> ""
            problem != null -> problem.orEmpty()
            status == CameraStatus.STARTING -> Hint.STARTING.text
            selfie && patient && !reading.hint.ready -> "Take it anyway"
            else -> reading.hint.text
        },
        trailing = {
            if (hasLight && !selfie && !unavailable) {
                CircleButton(if (lightOn) TablerIcons.Bolt else TablerIcons.BoltOff, if (lightOn) "Turn the light off" else "Turn the light on", { session.setTorch(!lightOn) })
            }
        },
        picture = {
            if (unavailable) {
                EmptyState(
                    TablerIcons.CameraOff,
                    "The camera won't open",
                    "Another app may be using it. Close other camera apps, then try again.",
                    Modifier.align(Alignment.Center),
                    actionLabel = "Try again",
                    onAction = onRetry,
                )
            } else {
                AndroidView(factory = { viewfinder }, modifier = Modifier.fillMaxSize())
                when (spec.kind) {
                    CaptureKind.DOCUMENT -> DocumentOverlay(reading.quad)
                    CaptureKind.PHOTO -> FramingMarks()
                    CaptureKind.SELFIE -> FaceOval(reading.hint.ready)
                }
                if (status == CameraStatus.STARTING) AuthProgress(Modifier.align(Alignment.Center))
                ShutterBlink(shooting)
            }
        },
        controls = {
            if (unavailable) {
                // A phone with no working camera can still send a file, selfie included.
                if (onChooseFile != null) LinkButton("Choose a file instead", onChooseFile, color = MaterialTheme.colorScheme.onBackground)
            } else {
                Box(Modifier.fillMaxSize()) {
                    if (onChooseFile != null && !selfie) {
                        CircleButton(TablerIcons.Photo, "Choose a file instead", onChooseFile, Modifier.align(Alignment.CenterStart))
                    }
                    ShutterButton(
                        enabled = status == CameraStatus.READY && (!selfie || reading.hint.ready || patient),
                        busy = shooting,
                        progress = if (shooting) 1f else reading.progress,
                        onClick = ::shoot,
                        modifier = Modifier.align(Alignment.Center),
                    )
                }
            }
        },
    )
}
