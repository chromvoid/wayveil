package app.wayveil

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import java.net.URI
import java.net.URL
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import java.util.Base64
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

object Invitation {
    const val ORIGIN = "https://link.chromvoid.com"

    fun parse(text: String): String {
        try {
            require(text.length <= 2048)
            val uri = URI(text.trim())
            val https = uri.scheme == "https" && uri.rawAuthority == "link.chromvoid.com" && uri.path in listOf("", "/")
            val app = uri.scheme == "wayveil" && uri.rawAuthority == "invite" && uri.path.isEmpty()
            require((https || app) && uri.rawQuery == null)
            val token = uri.rawFragment.orEmpty()
            require(token.matches(Regex("[A-Za-z0-9_-]{43}")) && Base64.getUrlDecoder().decode(token).size == 32)
            return token
        } catch (_: Exception) { throw AccessFailure("invalid_invitation") }
    }

    fun isLink(text: String) = text.trim().let { it.startsWith("https://") || it.startsWith("wayveil://invite") }
}

class AccessFailure(val code: String) : Exception(code) {
    val terminal get() = code in setOf("unauthorized", "access_expired", "access_revoked", "access_inactive")
    val messageResource get() = when (code) {
        "invalid_invitation" -> R.string.invalid_invitation
        "device_limit_reached" -> R.string.device_limit_reached
        "installation_conflict", "credential_conflict" -> R.string.activation_conflict
        "access_expired", "access_inactive" -> R.string.access_expired
        "access_revoked", "unauthorized" -> R.string.access_revoked
        "activating" -> R.string.access_activating
        "node_unavailable" -> R.string.node_unavailable
        "already_activated" -> R.string.already_activated
        "try_again_later" -> R.string.access_rate_limited
        else -> R.string.access_network_error
    }
}

// Persisted before enrollment so retries after a lost response use the same device slot.
class DeviceAccess(val installation: String, val token: String, val invitation: String = "", val device: String = "", val node: String = "") {
    fun toJson() = buildJsonObject {
        put("installation", installation); put("token", token); put("invitation", invitation); put("device", device); put("node", node)
    }.toString()

    fun enrolled(id: String) = DeviceAccess(installation, token, device = id, node = node)
    fun select(id: String) = DeviceAccess(installation, token, invitation, device, id)

    companion object {
        private fun secret() = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
        fun pending(invitation: String) = DeviceAccess(secret(), secret(), invitation)
        fun parse(text: String): DeviceAccess {
            val json = Json.parseToJsonElement(text).jsonObject
            fun field(name: String) = json.getValue(name).jsonPrimitive.content
            return DeviceAccess(field("installation"), field("token"), field("invitation"), field("device"), field("node"))
        }
    }
}

class CatalogNode(val id: String, val name: String, val profile: ConnectionProfile?, val expiresAt: Long) {
    val ready get() = profile != null
}

class NodeCatalog(val label: String, val expiresAt: Long, val nodes: List<CatalogNode>) {
    fun selected(id: String) = if (id.isEmpty()) nodes.firstOrNull { it.ready } else nodes.find { it.id == id }

    companion object {
        fun parse(json: JsonObject): NodeCatalog {
            val grant = json.getValue("grant").jsonObject
            val nodes = json.getValue("nodes").jsonArray.map { item ->
                val node = item.jsonObject
                fun field(key: String) = node[key]?.jsonPrimitive?.content.orEmpty()
                val ready = node.getValue("ready").jsonPrimitive.boolean
                val profile = if (ready) ConnectionProfile.parse(buildJsonObject {
                    put("name", field("name")); put("server", field("server")); put("server_port", node.getValue("server_port"))
                    put("password", field("ticket")); put("obfs_password", field("obfs_password"))
                    put("server_name", field("server_name")); put("certificate", field("certificate"))
                }.toString()) else null
                val expiry = if (ready) {
                    val claims = String(Base64.getUrlDecoder().decode(field("ticket").split('.')[1]), Charsets.UTF_8)
                    Json.parseToJsonElement(claims).jsonObject.getValue("exp").jsonPrimitive.long
                } else 0
                CatalogNode(field("id"), field("name"), profile, expiry)
            }
            require(nodes.map { it.id }.distinct().size == nodes.size)
            return NodeCatalog(grant.getValue("label").jsonPrimitive.content, grant.getValue("expires_at").jsonPrimitive.long, nodes)
        }
    }
}

data class AccessState(val catalog: NodeCatalog? = null, val loading: Boolean = false, val error: String? = null)

class AccessManager(private val context: Context, private val store: ProfileStore) {
    private val lock = Mutex()
    private val mutableState = MutableStateFlow(AccessState())
    val state = mutableState.asStateFlow()

    fun clearError() { mutableState.value = mutableState.value.copy(error = null) }

    suspend fun activate(text: String) = withContext(Dispatchers.IO) { lock.withLock {
        val invitation = Invitation.parse(text)
        val saved = store.access.value
        if (saved != null && (saved.device.isNotEmpty() || saved.invitation != invitation)) throw AccessFailure("already_activated")
        if (saved == null) store.saveAccess(DeviceAccess.pending(invitation))
        refreshLocked()
    } }

    suspend fun refresh(): NodeCatalog = withContext(Dispatchers.IO) { lock.withLock { refreshLocked() } }

    private fun refreshLocked(): NodeCatalog {
        mutableState.value = mutableState.value.copy(loading = true)
        try {
            var access = store.access.value ?: throw AccessFailure("unauthorized")
            if (access.device.isEmpty()) {
                val result = request("POST", "/v1/devices/enroll", "", buildJsonObject {
                    put("invite_token", access.invitation); put("api_token", access.token)
                    put("installation_id", access.installation); put("name", "Android " + Build.MODEL.take(60))
                })
                access = access.enrolled(result.getValue("device_id").jsonPrimitive.content)
                store.saveAccess(access)
            }
            val result = request("GET", "/v1/catalog", access.token)
            require(result.getValue("device_id").jsonPrimitive.content == access.device)
            val catalog = NodeCatalog.parse(result)
            if (access.node.isEmpty()) catalog.selected("")?.let { store.saveAccess(access.select(it.id)) }
            mutableState.value = AccessState(catalog)
            return catalog
        } catch (failure: AccessFailure) {
            mutableState.value = mutableState.value.copy(catalog = if (failure.terminal) null else mutableState.value.catalog, loading = false, error = failure.code)
            throw failure
        } catch (_: Exception) {
            mutableState.value = mutableState.value.copy(loading = false, error = "network_error")
            throw AccessFailure("network_error")
        }
    }

    suspend fun select(id: String) = withContext(Dispatchers.IO) { lock.withLock {
        require(mutableState.value.catalog?.nodes?.any { it.id == id && it.ready } == true)
        store.saveAccess(checkNotNull(store.access.value).select(id))
    } }

    suspend fun connection(): CatalogNode {
        val catalog = refresh()
        val node = catalog.selected(store.access.value?.node.orEmpty()) ?: throw AccessFailure("node_unavailable")
        if (!node.ready) throw AccessFailure("activating")
        if (node.expiresAt <= System.currentTimeMillis() / 1000) throw AccessFailure("activating")
        return node
    }

    suspend fun remove() = withContext(Dispatchers.IO) { lock.withLock {
        val access = store.access.value ?: return@withLock
        try { request("DELETE", "/v1/devices/self", access.token) }
        catch (failure: AccessFailure) { if (failure.code != "unauthorized") throw failure }
        store.removeAccess()
        mutableState.value = AccessState()
    } }

    private fun request(method: String, path: String, token: String, body: JsonObject? = null): JsonObject {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        // Control-plane requests must still work when the tunnel's old ticket has expired.
        val network = connectivity.allNetworks.firstOrNull {
            connectivity.getNetworkCapabilities(it)?.let { caps ->
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            } == true
        } ?: throw AccessFailure("network_error")
        val connection = network.openConnection(URL(Invitation.ORIGIN + path)) as HttpsURLConnection
        try {
            connection.connectTimeout = 10_000; connection.readTimeout = 10_000
            connection.instanceFollowRedirects = false; connection.useCaches = false; connection.requestMethod = method
            if (token.isNotEmpty()) connection.setRequestProperty("Authorization", "Bearer $token")
            if (body != null) {
                connection.doOutput = true; connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            if (status == 204) return buildJsonObject { }
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val bytes = stream?.use {
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    val count = it.read(buffer)
                    if (count < 0) break
                    require(output.size() + count <= 256 * 1024)
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            } ?: throw AccessFailure("network_error")
            require(bytes.size <= 256 * 1024)
            val result = Json.parseToJsonElement(String(bytes, Charsets.UTF_8)).jsonObject
            if (status !in 200..299) throw AccessFailure(result["error"]?.jsonPrimitive?.content ?: "network_error")
            return result
        } finally { connection.disconnect() }
    }
}
