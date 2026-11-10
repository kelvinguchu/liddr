package com.liddr.app

import android.app.Activity
import android.app.Application
import android.os.Bundle
import java.util.concurrent.atomic.AtomicInteger
import com.liddr.app.data.DriverApi
import com.liddr.app.data.KeystoreTokenStore
import com.liddr.app.data.LiddrApi
import com.liddr.app.data.Locator
import com.liddr.app.data.GeocoderPlaceFinder
import com.liddr.app.data.GooglePlaceFinder
import com.liddr.app.data.PlaceFinder
import com.liddr.app.data.Realtime
import com.liddr.app.data.SendApi
import com.liddr.app.data.SessionManager
import com.liddr.app.data.Transport

/** Builds the app's long-lived objects once, for every screen to share. */
class LiddrApp : Application() {
    private val started = AtomicInteger()

    /** True while any screen of the app is visible. */
    val isVisible: Boolean get() = started.get() > 0

    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                started.incrementAndGet()
            }

            override fun onActivityStopped(activity: Activity) {
                started.decrementAndGet()
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }

    val session: SessionManager by lazy { SessionManager(transport, KeystoreTokenStore(this)) }
    val api: LiddrApi by lazy { LiddrApi(transport, session) }

    val realtime: Realtime by lazy { Realtime(BuildConfig.API_BASE_URL, session) }
    val send: SendApi by lazy { SendApi(transport, session) }
    val drivers: DriverApi by lazy { DriverApi(transport, session) }
    val locator: Locator by lazy { Locator(this) }
    val places: PlaceFinder by lazy {
        if (BuildConfig.MAPS_API_KEY.isBlank()) GeocoderPlaceFinder(this) else GooglePlaceFinder(this, BuildConfig.MAPS_API_KEY)
    }

    private val transport by lazy { Transport(BuildConfig.API_BASE_URL) }
}
