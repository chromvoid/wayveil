package app.wayveil

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import com.chromvoid.core.mobile.Platform

class BoxPlatform(private val service: VpnService, private val networkChanged: () -> Unit) : Platform {
    private val connectivity = service.getSystemService(ConnectivityManager::class.java)
    @Volatile private var network: Network? = null
    @Volatile private var descriptor: ParcelFileDescriptor? = null
    private var registered = false
    @Volatile private var lastNetwork = ""

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(value: Network) { network = value; updateNetwork() }
        override fun onLinkPropertiesChanged(value: Network, properties: LinkProperties) {
            if (network == value) updateNetwork()
        }
        override fun onCapabilitiesChanged(value: Network, capabilities: NetworkCapabilities) {
            if (network == value) updateNetwork()
        }
        override fun onLost(value: Network) {
            if (network == value) { network = null; updateNetwork() }
        }
    }

    fun start() {
        network = connectivity.allNetworks.firstOrNull {
            connectivity.getNetworkCapabilities(it)?.let { caps ->
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            } == true
        }
        updateNetwork(notify = false)
        val request = NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build()
        val handler = Handler(Looper.getMainLooper())
        if (Build.VERSION.SDK_INT >= 31) connectivity.registerBestMatchingNetworkCallback(request, callback, handler)
        else connectivity.requestNetwork(request, callback, handler)
        registered = true
    }

    fun openTun() {
        check(VpnService.prepare(service) == null) { "VPN permission is required" }
        check(descriptor == null) { "The VPN interface is already open" }
        val builder = service.Builder().setSession(service.getString(R.string.app_name)).setMtu(1400).setMetered(false)
            .addAddress("172.19.0.1", 30).addAddress("fdfe:dcba:9876::1", 126)
            .addDnsServer("172.19.0.2")
            .addRoute("0.0.0.0", 0).addRoute("::", 0)
        network?.let { builder.setUnderlyingNetworks(arrayOf(it)) }
        descriptor = builder.establish() ?: error("VPN permission was revoked")
    }

    fun duplicateTun(): Int = ParcelFileDescriptor.dup(checkNotNull(descriptor).fileDescriptor).detachFd()

    override fun protectSocket(fd: Long) {
        require(fd in 0..Int.MAX_VALUE) { "Invalid transport socket" }
        val current = network ?: error("The physical network is unavailable")
        check(service.protect(fd.toInt())) { "Could not protect the transport socket" }
        ParcelFileDescriptor.fromFd(fd.toInt()).use { current.bindSocket(it.fileDescriptor) }
    }

    private fun updateNetwork(notify: Boolean = true) {
        val current = network
        val properties = current?.let(connectivity::getLinkProperties)
        val signature = "${current?.networkHandle}/${properties?.interfaceName}"
        if (descriptor != null) service.setUnderlyingNetworks(current?.let { arrayOf(it) })
        if (signature != lastNetwork) {
            lastNetwork = signature
            if (notify) networkChanged()
        }
    }

    fun close() {
        if (registered) { connectivity.unregisterNetworkCallback(callback); registered = false }
        descriptor?.close()
        descriptor = null
        network = null
    }
}
