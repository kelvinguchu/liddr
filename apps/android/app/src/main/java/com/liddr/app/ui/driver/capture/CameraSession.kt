package com.liddr.app.ui.driver.capture

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Size
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.TorchState
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.lifecycle.awaitInstance
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.Observer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.suspendCancellableCoroutine

/** The camera could not be opened, or the photo could not be taken. */
internal class CameraFailure(cause: Throwable? = null) : Exception(cause)

private val ANALYSIS_SIZE = Size(640, 480)
private val PHOTO_SIZE = Size(2880, 2160)
private const val CAMERA_JPEG_QUALITY = 95

/**
 * One use of the camera: a viewfinder, a still photo and, for documents and
 * selfies, a frame reader. Everything is 4:3 so the viewfinder, the reader and
 * the photo see the same picture.
 *
 * What stops it: [close], which unbinds the camera and so ends the frame
 * reader, then shuts the one thread the reader and the photo decode run on.
 * The screen calls it when it leaves. Use from the main thread.
 */
internal class CameraSession(private val context: Context, private val kind: CaptureKind) {
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val _reading = MutableStateFlow(LiveReading())
    private val _torchOn = MutableStateFlow(false)
    private val fourByThree = AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY
    private val preview = Preview.Builder()
        .setResolutionSelector(ResolutionSelector.Builder().setAspectRatioStrategy(fourByThree).build())
        .build()
    private val photo = ImageCapture.Builder()
        // A document is read by a person, so take the sharper, slower photo for it.
        .setCaptureMode(if (kind == CaptureKind.DOCUMENT) ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY else ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
        .setJpegQuality(CAMERA_JPEG_QUALITY)
        .setResolutionSelector(selector(PHOTO_SIZE))
        .build()
    private val reader = ImageAnalysis.Builder()
        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
        .setResolutionSelector(selector(ANALYSIS_SIZE))
        .build()
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var closed = false
    private val torchWatch = Observer<Int> { _torchOn.value = it == TorchState.ON }

    /** What the frame reader sees, updated a few times a second. */
    val reading: StateFlow<LiveReading> = _reading
    val torchOn: StateFlow<Boolean> = _torchOn

    /** Opens the camera into [surface]. Returns whether it has a light. Throws [CameraFailure]. */
    suspend fun start(owner: LifecycleOwner, surface: Preview.SurfaceProvider): Boolean {
        val cameras = try {
            ProcessCameraProvider.awaitInstance(context)
        } catch (e: IllegalStateException) {
            throw CameraFailure(e)
        }
        if (closed) throw CameraFailure()
        val wanted = if (kind == CaptureKind.SELFIE) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        val other = if (kind == CaptureKind.SELFIE) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA
        val lens = listOf(wanted, other).firstOrNull { runCatching { cameras.hasCamera(it) }.getOrDefault(false) } ?: throw CameraFailure()
        preview.surfaceProvider = surface
        val bound = try {
            if (kind == CaptureKind.PHOTO) {
                cameras.bindToLifecycle(owner, lens, preview, photo)
            } else {
                reader.setAnalyzer(worker, FrameAnalyzer(kind, SystemClock::elapsedRealtime) { _reading.value = it })
                cameras.bindToLifecycle(owner, lens, preview, photo, reader)
            }
        } catch (e: IllegalArgumentException) {
            throw CameraFailure(e)
        } catch (e: IllegalStateException) {
            throw CameraFailure(e)
        }
        provider = cameras
        camera = bound
        if (kind == CaptureKind.PHOTO) _reading.value = LiveReading(Hint.FRAME_VEHICLE)
        // The light goes out when the camera pauses, so follow the camera rather than the button.
        bound.cameraInfo.torchState.observe(owner, torchWatch)
        return bound.cameraInfo.hasFlashUnit()
    }

    fun setTorch(on: Boolean) {
        // The result is not awaited: the torch state above reports what happened.
        camera?.cameraControl?.enableTorch(on)
    }

    /** Takes the photo and returns it upright. Throws [CameraFailure]. */
    suspend fun shoot(): Bitmap = suspendCancellableCoroutine { waiting ->
        if (closed) {
            waiting.resumeWith(Result.failure(CameraFailure()))
            return@suspendCancellableCoroutine
        }
        photo.takePicture(worker, object : ImageCapture.OnImageCapturedCallback() {
            override fun onCaptureSuccess(image: ImageProxy) {
                val bitmap = try {
                    val buffer = image.planes[0].buffer
                    val jpeg = ByteArray(buffer.remaining()).also { buffer.get(it) }
                    decodeUpright(jpeg, image.imageInfo.rotationDegrees)
                } catch (_: OutOfMemoryError) {
                    null
                } finally {
                    image.close()
                }
                waiting.resumeWith(if (bitmap != null) Result.success(bitmap) else Result.failure(CameraFailure()))
            }

            override fun onError(exception: ImageCaptureException) {
                waiting.resumeWith(Result.failure(CameraFailure(exception)))
            }
        })
    }

    fun close() {
        if (closed) return
        closed = true
        reader.clearAnalyzer()
        camera?.cameraInfo?.torchState?.removeObserver(torchWatch)
        provider?.unbind(preview, photo, reader)
        camera = null
        worker.shutdown()
    }

    private fun selector(size: Size) = ResolutionSelector.Builder()
        .setAspectRatioStrategy(fourByThree)
        .setResolutionStrategy(ResolutionStrategy(size, ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
        .build()
}
