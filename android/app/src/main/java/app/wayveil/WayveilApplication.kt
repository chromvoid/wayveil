package app.wayveil

import android.app.Application

class WayveilApplication : Application() {
    lateinit var profiles: ProfileStore
        private set
    lateinit var access: AccessManager
        private set

    override fun onCreate() {
        super.onCreate()
        profiles = ProfileStore(this)
        access = AccessManager(this, profiles)
    }
}
