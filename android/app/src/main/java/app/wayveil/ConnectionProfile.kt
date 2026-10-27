package app.wayveil

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets.UTF_8
import java.security.cert.CertificateFactory
import java.util.Base64
import kotlinx.serialization.json.*

enum class RoutingMode { ALL, RUSSIAN_DIRECT }

class ConnectionProfile(
    val name: String,
    val server: String,
    val port: Int,
    val password: String,
    val obfsPassword: String,
    val serverName: String,
    val certificate: String,
) {
    fun toJson(): String = buildJsonObject {
        put("version", 1)
        put("name", name)
        put("server", server)
        put("server_port", port)
        put("password", password)
        put("obfs_password", obfsPassword)
        put("server_name", serverName)
        put("certificate", certificate)
    }.toString()

    companion object {
        const val MAX_LENGTH = 65_536

        fun parse(text: String): ConnectionProfile {
            if (text.length > MAX_LENGTH) throw ProfileError("The profile is too large.")
            return try {
                val input = text.trim()
                val profile = when {
                    input.startsWith("{") -> fromJson(Json.parseToJsonElement(input).jsonObject)
                    input.startsWith("wayveil://") -> {
                        val uri = URI(input)
                        require(uri.host == "profile") { "Unknown Wayveil link." }
                        val data = query(uri)["data"] ?: error("Missing profile data.")
                        fromJson(Json.parseToJsonElement(String(Base64.getUrlDecoder().decode(data), UTF_8)).jsonObject)
                    }
                    input.startsWith("hysteria2://") || input.startsWith("hy2://") -> fromUri(URI(input))
                    else -> throw IllegalArgumentException("Use a Wayveil profile or a Hysteria2 link.")
                }
                profile.validate()
                profile
            } catch (error: IllegalArgumentException) {
                if (error is ProfileError) throw error
                throw ProfileError("Invalid profile. Check the server, credentials, and TLS settings.")
            } catch (_: Exception) {
                throw ProfileError("Invalid profile. Check the server, credentials, and TLS settings.")
            }
        }

        private fun fromJson(json: JsonObject): ConnectionProfile {
            val fields = setOf("version", "name", "server", "server_port", "password", "obfs_password", "server_name", "certificate")
            if (json.keys.any { it !in fields }) throw ProfileError("Unsupported profile fields. Import a Wayveil profile, not a complete sing-box configuration.")
            require(json["version"]?.jsonPrimitive?.int ?: 1 == 1)
            fun field(key: String, fallback: String = "") = json[key]?.jsonPrimitive?.content ?: fallback
            return ConnectionProfile(
                field("name", field("server")), field("server"),
                json["server_port"]?.jsonPrimitive?.int ?: 443,
                field("password"), field("obfs_password"),
                field("server_name", field("server")), field("certificate"),
            )
        }

        private fun fromUri(uri: URI): ConnectionProfile {
            val params = query(uri)
            if (params["insecure"]?.let { it != "0" && it != "false" } == true) {
                throw ProfileError("TLS verification is required. Import a Wayveil profile with the server certificate.")
            }
            if ("pinSHA256" in params) throw ProfileError("Certificate fingerprint links are not supported. Import a Wayveil profile with its PEM certificate.")
            if (params.keys.any { it !in setOf("sni", "obfs", "obfs-password", "insecure") }) {
                throw ProfileError("This Hysteria2 link uses unsupported options.")
            }
            require(params["obfs"] == null || params["obfs"] == "salamander")
            if (params["obfs"] == "salamander") require(!params["obfs-password"].isNullOrBlank())
            if (params["obfs"] == null) require(params["obfs-password"].isNullOrEmpty())
            val host = uri.host?.removeSurrounding("[", "]") ?: throw ProfileError("The link must contain a server and a single numeric port.")
            return ConnectionProfile(
                uri.rawFragment?.let(::decode)?.takeIf(String::isNotBlank) ?: host,
                host, if (uri.port == -1) 443 else uri.port,
                uri.rawUserInfo?.let(::decode).orEmpty(), params["obfs-password"].orEmpty(),
                params["sni"] ?: host, "",
            )
        }

        private fun query(uri: URI): Map<String, String> = uri.rawQuery.orEmpty()
            .split('&').filter(String::isNotEmpty).associate { part ->
                val pair = part.split('=', limit = 2)
                decode(pair[0]) to decode(pair.getOrElse(1) { "" })
            }

        private fun decode(value: String) = URLDecoder.decode(value.replace("+", "%2B"), UTF_8.name())
    }

    private fun validate() {
        require(name.isNotBlank() && name.length <= 80)
        require(server.isNotBlank() && server.length <= 253 && server.none { it.isWhitespace() || it in "/@?#" })
        require(port in 1..65535 && password.isNotBlank())
        require(serverName.isNotBlank() && serverName.none { it.isWhitespace() || it in "/@?#" })
        if (certificate.isNotBlank()) {
            require(certificate.contains("-----BEGIN CERTIFICATE-----"))
            require(CertificateFactory.getInstance("X.509").generateCertificates(certificate.byteInputStream()).isNotEmpty())
        }
    }
}

class ProfileError(message: String) : IllegalArgumentException(message)
