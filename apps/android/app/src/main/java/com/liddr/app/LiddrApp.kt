package com.liddr.app

import android.app.Application
import com.liddr.app.data.DriverApi
import com.liddr.app.data.KeystoreTokenStore
import com.liddr.app.data.LiddrApi
import com.liddr.app.data.Locator
import com.liddr.app.data.PlaceFinder
import com.liddr.app.data.SessionManager
import com.liddr.app.data.Transport

/** Builds the app's long-lived objects once, for every screen to share. */
class LiddrApp : Application() {
    val session: SessionManager by lazy { SessionManager(transport, KeystoreTokenStore(this)) }
    val api: LiddrApi by lazy { LiddrApi(transport, session) }

    val drivers: DriverApi by lazy { DriverApi(transport, session) }
    val locator: Locator by lazy { Locator(this) }
    val places: PlaceFinder by lazy { PlaceFinder(this) }

    private val transport by lazy { Transport(BuildConfig.API_BASE_URL) }
}
