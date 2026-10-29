package app.wayveil

import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.IpPrefix
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
import java.net.InetAddress

class TunnelPlatform(private val service: VpnService, private val networkChanged: () -> Unit) : Platform {
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
        // Android Auto refuses to project while its traffic goes through a VPN, and wireless
        // head units are reached over the local network, so both stay outside the tunnel.
        try { builder.addDisallowedApplication(ANDROID_AUTO) } catch (_: PackageManager.NameNotFoundException) {}
        if (Build.VERSION.SDK_INT >= 33) LOCAL_NETWORKS.forEach { (address, length) ->
            builder.excludeRoute(IpPrefix(InetAddress.getByName(address), length))
        }
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

    private companion object {
        const val ANDROID_AUTO = "com.google.android.projection.gearhead"
        // The tunnel's own 172.19.0.0/30 and fdfe:dcba:9876::/126 are more specific and stay routed.
        val LOCAL_NETWORKS = listOf(
            "10.0.0.0" to 8, "172.16.0.0" to 12, "192.168.0.0" to 16, "169.254.0.0" to 16,
            "fc00::" to 7, "fe80::" to 10,
        )
    }
}
