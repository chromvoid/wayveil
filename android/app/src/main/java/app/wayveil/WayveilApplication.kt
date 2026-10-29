package app.wayveil

import android.app.Application

class WayveilApplication : Application() {
    lateinit var profiles: ProfileStore
        private set
    lateinit var access: AccessManager
        private set
    lateinit var routing: RoutingRulesStore
        private set

    override fun onCreate() {
        super.onCreate()
        profiles = ProfileStore(this)
        routing = RoutingRulesStore.create(this, profiles)
        access = AccessManager(this, profiles, routing)
    }
}
