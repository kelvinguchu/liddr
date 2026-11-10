package com.liddr.app.service

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.liddr.app.LiddrApp
import com.liddr.app.MainActivity
import com.liddr.app.R
import com.liddr.app.data.Coordinates
import com.liddr.app.data.Offer
import com.liddr.app.data.SessionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** Starts and stops the service from a screen. */
class DriverLocationControl(private val context: Context) {
    fun start() = ContextCompat.startForegroundService(context, Intent(context, DriverLocationService::class.java))

    fun stop() {
        context.stopService(Intent(context, DriverLocationService::class.java))
    }
}

/**
 * Sends the driver's position while they are online, including with the screen
 * off. It shows a permanent notification, stops when they go offline, and stops
 * by itself if they sign out.
 */
class DriverLocationService : Service(), LocationListener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val manager by lazy { getSystemService(LocationManager::class.java) }
    private var listening = false

    override fun onBind(intent: Intent?): IBinder? = null

    @SuppressLint("MissingPermission") // The screen asks for permission before going online.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(), serviceType())
        if (!listening) {
            listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter(manager::isProviderEnabled).forEach {
                manager.requestLocationUpdates(it, INTERVAL_MS, 0f, this, Looper.getMainLooper())
            }
            listening = true
            scope.launch {
                (application as LiddrApp).session.state.first { it is SessionState.SignedOut }
                stopSelf()
            }
            scope.launch { watchOffers() }
        }
        return START_STICKY
    }

    override fun onLocationChanged(location: Location) {
        val app = application as LiddrApp
        scope.launch {
            // A dropped ping is replaced by the next one seconds later.
            runCatching { app.drivers.updateLocation(Coordinates(location.latitude, location.longitude)) }
        }
    }

    /**
     * While the app is out of sight, offers would otherwise go unseen until they
     * expire, so they are announced. On screen, the app shows them itself.
     */
    private suspend fun watchOffers() {
        val app = application as LiddrApp
        var announced = emptySet<String>()
        while (true) {
            delay(OFFER_CHECK_MS)
            if (app.isVisible) {
                notifications.cancel(OFFER_NOTIFICATION_ID)
                continue
            }
            val offers = runCatching { app.drivers.listOffers() }.getOrNull() ?: continue
            val fresh = offers.firstOrNull { it.id !in announced }
            when {
                offers.isEmpty() -> notifications.cancel(OFFER_NOTIFICATION_ID)
                fresh != null -> notifications.notify(OFFER_NOTIFICATION_ID, offerNotification(fresh))
            }
            announced = offers.mapTo(mutableSetOf()) { it.id }
        }
    }

    private val notifications by lazy { getSystemService(NotificationManager::class.java) }

    private fun offerNotification(offer: Offer): Notification {
        notifications.createNotificationChannel(NotificationChannel(OFFER_CHANNEL, "Trip offers", NotificationManager.IMPORTANCE_HIGH))
        return NotificationCompat.Builder(this, OFFER_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("New trip · ${"KES %,d".format(offer.fareKes)}")
            .setContentText("Pickup ${"%.1f".format(offer.distanceToPickupM / 1000.0)} km away. Open Liddr to accept.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setContentIntent(openApp())
            .setAutoCancel(true)
            .setTimeoutAfter(OFFER_TIMEOUT_MS)
            .build()
    }

    private fun openApp() = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE,
    )

    override fun onDestroy() {
        notifications.cancel(OFFER_NOTIFICATION_ID)
        manager.removeUpdates(this)
        scope.cancel()
        super.onDestroy()
    }

    private fun serviceType() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0

    private fun notification(): Notification {
        val channel = NotificationChannel(CHANNEL, "Online status", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        val open = openApp()
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("You're online")
            .setContentText("Liddr is sharing your location so riders can find you.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    private companion object {
        const val CHANNEL = "driver_online"
        const val NOTIFICATION_ID = 7
        const val INTERVAL_MS = 3_000L
        const val OFFER_CHANNEL = "trip_offers"
        const val OFFER_NOTIFICATION_ID = 8
        const val OFFER_CHECK_MS = 4_000L
        const val OFFER_TIMEOUT_MS = 20_000L
    }
}
