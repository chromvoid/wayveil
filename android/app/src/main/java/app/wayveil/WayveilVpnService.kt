package app.wayveil

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.chromvoid.core.mobile.Engine
import com.chromvoid.core.mobile.Mobile
import java.net.URL
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject

enum class TunnelPhase { DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING, STOPPING, ERROR }
data class TunnelStatus(val phase: TunnelPhase = TunnelPhase.DISCONNECTED, val error: String? = null) {
    val running get() = phase in setOf(TunnelPhase.CONNECTING, TunnelPhase.CONNECTED, TunnelPhase.RECONNECTING, TunnelPhase.STOPPING)
}

class WayveilVpnService : VpnService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Mutex()
    private var core: Engine? = null
    private var platform: TunnelPlatform? = null
    private var packetThread: Thread? = null
    private var healthJob: Job? = null
    private var accessJob: Job? = null
    private var ticketExpiresAt = 0L
    private var activeProfile: ConnectionProfile? = null
    private var activeRules: JsonObject? = null
    private var activeRoutingMode = RoutingMode.ALL
    private var generation = 0L
    private var needsReconnect = false
    private var lastHealthLog = 0L
    private val healthWakeups = Channel<Unit>(Channel.CONFLATED)
    private val probe = AtomicReference<HttpsURLConnection?>()
    private var receiverRegistered = false
    private val idleReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!getSystemService(PowerManager::class.java).isDeviceIdleMode) {
                scope.launch { lock.withLock { reconnectCore() } }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) { requestStop(); return START_NOT_STICKY }
        try {
            val notification = notification(R.string.connecting)
            if (Build.VERSION.SDK_INT >= 34) startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
            else startForeground(1, notification)
        } catch (_: Exception) {
            state.value = TunnelStatus(TunnelPhase.ERROR, getString(R.string.start_failed))
            stopSelf()
            return START_NOT_STICKY
        }
        scope.launch { lock.withLock { if (core == null && packetThread == null) startTunnel() } }
        return START_STICKY
    }

    private suspend fun startTunnel() {
        val app = application as WayveilApplication
        val store = app.profiles
        if ((store.profile.value == null && store.access.value == null) || prepare(this) != null || !store.consentGranted()) {
            state.value = TunnelStatus(TunnelPhase.ERROR, getString(R.string.profile_or_permission_required))
            stopSelf()
            return
        }
        state.value = TunnelStatus(TunnelPhase.CONNECTING)
        try {
            val managed = store.access.value != null
            val node = if (managed) app.access.connection() else null
            val profile = node?.profile ?: checkNotNull(store.profile.value)
            val mode = store.mode.value
            val rules = app.routing.rules(mode)
            val config = TunnelConfig.create(profile, mode, rules)
            Mobile.validate(config)
            val adapter = TunnelPlatform(this) { scope.launch { lock.withLock { reconnectCore() } } }
            platform = adapter
            adapter.start()
            core = Mobile.start(config, adapter)
            adapter.openTun()
            startPackets(adapter, checkNotNull(core))
            activeProfile = profile
            activeRules = rules
            activeRoutingMode = mode
            ticketExpiresAt = node?.expiresAt ?: 0
            needsReconnect = false
            ContextCompat.registerReceiver(this, idleReceiver,
                IntentFilter().apply {
                    addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                    addAction(Intent.ACTION_SCREEN_ON)
                }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
            healthJob = scope.launch { monitorConnection() }
            if (managed) accessJob = scope.launch { monitorAccess() }
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            Log.e("Wayveil", "Tunnel startup failed: ${error.javaClass.simpleName}")
            cleanup()
            state.value = TunnelStatus(TunnelPhase.ERROR, getString(if (error is AccessFailure) error.messageResource else R.string.start_failed))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun startPackets(adapter: TunnelPlatform, engine: Engine) {
        check(packetThread == null) { "The packet loop is already running" }
        val native = HevTunnel
        val config = engine.hevConfig()
        val fd = adapter.duplicateTun()
        var prepared = false
        try {
            native.prepare()
            prepared = true
            val worker = Thread({
                val current = Thread.currentThread()
                val result = runCatching { native.run(config, fd) }
                scope.launch { lock.withLock {
                    if (packetThread === current && core != null && state.value.phase != TunnelPhase.STOPPING) {
                        Log.e("Wayveil", "Packet loop stopped: ${result.getOrNull() ?: result.exceptionOrNull()?.javaClass?.simpleName}")
                        failAccess(R.string.start_failed)
                    }
                } }
            }, "Wayveil packets")
            packetThread = worker
            worker.start()
        } catch (error: Throwable) {
            packetThread = null
            if (prepared) {
                native.stop()
                native.run(config, fd)
            } else android.os.ParcelFileDescriptor.adoptFd(fd).close()
            throw error
        }
    }

    private fun stopPackets() {
        val worker = packetThread ?: return
        logPacketStats("Stopping packet loop")
        HevTunnel.stop()
        worker.join(10_000)
        check(!worker.isAlive) { "The packet loop did not stop" }
        packetThread = null
    }

    private fun reconnectCore() {
        val engine = core ?: return
        generation++
        needsReconnect = true
        if (state.value.phase == TunnelPhase.CONNECTED) {
            state.value = TunnelStatus(TunnelPhase.RECONNECTING)
            updateNotification(R.string.reconnecting)
        }
        try { engine.reconnect(); needsReconnect = false }
        catch (_: Exception) { }
        healthWakeups.trySend(Unit)
    }

    private suspend fun monitorAccess() {
        val app = application as WayveilApplication
        while (currentCoroutineContext().isActive) {
            delay(30_000)
            try {
                val node = app.access.connection()
                val replacement = checkNotNull(node.profile)
                lock.withLock {
                    val current = activeProfile ?: return@withLock
                    val changed = current.server != replacement.server || current.port != replacement.port ||
                        current.serverName != replacement.serverName || current.obfsPassword != replacement.obfsPassword || current.certificate != replacement.certificate
                    if (core != null && (ticketExpiresAt - System.currentTimeMillis() / 1000 <= 300 || changed)) {
                        val config = TunnelConfig.create(replacement, activeRoutingMode, checkNotNull(activeRules))
                        Mobile.validate(config)
                        state.value = TunnelStatus(TunnelPhase.RECONNECTING)
                        updateNotification(R.string.reconnecting)
                        generation++
                        stopPackets()
                        core?.close()
                        core = null
                        val adapter = checkNotNull(platform)
                        core = Mobile.start(config, adapter)
                        startPackets(adapter, checkNotNull(core))
                        activeProfile = replacement
                        ticketExpiresAt = node.expiresAt
                        needsReconnect = false
                        healthWakeups.trySend(Unit)
                    }
                }
            } catch (failure: AccessFailure) {
                if (failure.terminal) {
                    lock.withLock { failAccess(failure.messageResource) }
                    return
                }
                // Keep the TUN in place during outages; the next refresh can recover it.
            } catch (failure: CancellationException) { throw failure }
            catch (_: Exception) { lock.withLock { failAccess(R.string.start_failed) }; return }
        }
    }

    private fun failAccess(message: Int) {
        cleanup()
        state.value = TunnelStatus(TunnelPhase.ERROR, getString(message))
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private suspend fun monitorConnection() {
        while (currentCoroutineContext().isActive) {
            val snapshot = lock.withLock { core?.let { Triple(it, generation, needsReconnect) } } ?: return
            val (engine, currentGeneration, retry) = snapshot
            if (retry) lock.withLock {
                if (core === engine && generation == currentGeneration) {
                    try { engine.reconnect() }
                    catch (_: Exception) { }
                }
            }
            val reachable = checkConnection(engine, currentGeneration)
            currentCoroutineContext().ensureActive()
            lock.withLock {
                if (core === engine && generation == currentGeneration && state.value.phase != TunnelPhase.STOPPING) {
                    needsReconnect = !reachable
                    state.value = TunnelStatus(if (reachable) TunnelPhase.CONNECTED else TunnelPhase.RECONNECTING)
                    updateNotification(if (reachable) R.string.connected else R.string.reconnecting)
                    val now = android.os.SystemClock.elapsedRealtime()
                    if (reachable && now - lastHealthLog >= 30_000) {
                        lastHealthLog = now
                        logPacketStats("VPN health OK; core=${Mobile.version()}")
                    }
                }
            }
            withTimeoutOrNull(if (reachable) 30_000L else 5_000L) { healthWakeups.receive() }
        }
    }

    private suspend fun checkConnection(engine: Engine, currentGeneration: Long): Boolean {
        try { engine.check() }
        catch (_: Exception) { return false }
        currentCoroutineContext().ensureActive()
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val network = connectivity.allNetworks.firstOrNull { network ->
            connectivity.getNetworkCapabilities(network)?.let {
                it.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    (Build.VERSION.SDK_INT < 30 || it.ownerUid == Process.myUid())
            } == true
        } ?: return false
        val connection = try {
            network.openConnection(URL("https://1.1.1.1/cdn-cgi/trace")) as HttpsURLConnection
        } catch (_: Exception) { return false }
        return try {
            val current = lock.withLock {
                if (core !== engine || generation != currentGeneration || state.value.phase == TunnelPhase.STOPPING) false
                else { probe.set(connection); true }
            }
            if (!current) return false
            connection.connectTimeout = 8_000
            connection.readTimeout = 8_000
            connection.useCaches = false
            connection.instanceFollowRedirects = false
            connection.responseCode == 200
        } catch (error: CancellationException) { throw error }
        catch (_: Exception) { false }
        finally { connection.disconnect(); probe.compareAndSet(connection, null) }
    }

    private fun logPacketStats(message: String) {
        val stats = HevTunnel.stats()
        Log.i("Wayveil", "$message; HEV txPackets=${stats[0]} txBytes=${stats[1]} rxPackets=${stats[2]} rxBytes=${stats[3]}")
    }

    private fun requestStop() {
        state.value = TunnelStatus(TunnelPhase.STOPPING)
        healthJob?.cancel()
        probe.getAndSet(null)?.disconnect()
        scope.launch { lock.withLock {
            val closed = cleanup()
            state.value = if (closed) TunnelStatus() else TunnelStatus(TunnelPhase.ERROR, getString(R.string.start_failed))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        } }
    }

    private fun cleanup(): Boolean {
        generation++
        accessJob?.cancel()
        accessJob = null
        activeProfile = null
        activeRules = null
        ticketExpiresAt = 0
        healthJob?.cancel()
        healthJob = null
        probe.getAndSet(null)?.disconnect()
        if (receiverRegistered) { unregisterReceiver(idleReceiver); receiverRegistered = false }
        val packetStopped = try { stopPackets(); true }
        catch (_: Exception) { Log.e("Wayveil", "Packet loop shutdown failed"); false }
        try { core?.close() } catch (_: Exception) { }
        core = null
        platform?.close()
        platform = null
        return packetStopped
    }

    override fun onRevoke() { requestStop() }
    override fun onDestroy() {
        healthJob?.cancel()
        probe.getAndSet(null)?.disconnect()
        scope.launch { lock.withLock {
            val closed = cleanup()
            if (state.value.phase != TunnelPhase.ERROR) {
                state.value = if (closed) TunnelStatus() else TunnelStatus(TunnelPhase.ERROR, getString(R.string.start_failed))
            }
        } }.invokeOnCompletion { scope.cancel() }
        super.onDestroy()
    }

    private fun notification(status: Int): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("tunnel", getString(R.string.vpn_channel), NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, WayveilVpnService::class.java).setAction(STOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(this, "tunnel")
            .setSmallIcon(R.drawable.ic_vpn).setContentTitle(getString(R.string.app_name)).setContentText(getString(status))
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(0, getString(R.string.disconnect), stop).build()
    }

    private fun updateNotification(status: Int) {
        getSystemService(NotificationManager::class.java).notify(1, notification(status))
    }

    companion object {
        private const val STOP = "app.wayveil.STOP"
        private val state = MutableStateFlow(TunnelStatus())
        val status = state.asStateFlow()
        fun clearError() { if (state.value.phase == TunnelPhase.ERROR) state.value = TunnelStatus() }
        fun start(context: Context) { ContextCompat.startForegroundService(context, Intent(context, WayveilVpnService::class.java)) }
        fun stop(context: Context) { context.startService(Intent(context, WayveilVpnService::class.java).setAction(STOP)) }
    }
}
