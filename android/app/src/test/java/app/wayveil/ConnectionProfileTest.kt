package app.wayveil

import java.util.Base64
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ConnectionProfileTest {
    private val profile = ConnectionProfile("Personal server", "vpn.example.com", 46219, "secret@+:/", "obfs-secret", "vpn.example.com", "")

    @Test fun importsHysteriaCredentialsWithoutChangingPercentEncoding() {
        val value = ConnectionProfile.parse("hy2://secret%40%2B%3A%2F@vpn.example.com:46219?obfs=salamander&obfs-password=obfs-secret&sni=vpn.example.com#Personal%20server")
        assertEquals(profile.password, value.password)
        assertEquals(profile.port, value.port)
        assertEquals(profile.name, value.name)
        assertEquals(profile.obfsPassword, value.obfsPassword)
    }

    @Test fun importsWayveilLinksAndRoundTripsTheStoredProfile() {
        val data = Base64.getUrlEncoder().withoutPadding().encodeToString(profile.toJson().toByteArray())
        val value = ConnectionProfile.parse("wayveil://profile?data=$data")
        assertEquals(profile.toJson(), value.toJson())
    }

    @Test fun rejectsInsecureTlsAndUnsupportedCertificateFingerprints() {
        listOf("?insecure=1", "?pinSHA256=deadbeef", "?obfs=gecko", "?obfs=salamander").forEach { query ->
            assertThrows(ProfileError::class.java) { ConnectionProfile.parse("hy2://password@vpn.example.com$query") }
        }
    }

    @Test fun rejectsMalformedProfilesWithoutExposingCredentialsInErrors() {
        val secret = "do-not-include-this-in-errors"
        val invalid = profile.toJson().replace("\"server_port\":46219", "\"server_port\":0").replace(profile.password, secret)
        val error = assertThrows(ProfileError::class.java) { ConnectionProfile.parse(invalid) }
        assertFalse(error.message.orEmpty().contains(secret))
        assertThrows(ProfileError::class.java) { ConnectionProfile.parse("x".repeat(ConnectionProfile.MAX_LENGTH + 1)) }
    }

    @Test fun coreConfigurationPreservesTheProfileAndSelectedRoutingMode() {
        for (mode in RoutingMode.entries) {
            val config = Json.parseToJsonElement(TunnelConfig.create(profile, mode)).jsonObject
            assertEquals(Json.parseToJsonElement(profile.toJson()), config.getValue("profile"))
            assertEquals(mode.name, config.getValue("routing").jsonPrimitive.content)
            assertEquals(setOf("profile", "routing"), config.keys)
        }
    }

    @Test fun invitationOnlyAcceptsTheOwnedOriginAndNeverReturnsSecretsInErrors() {
        val token = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 17 })
        assertEquals(token, Invitation.parse("https://link.chromvoid.com/#$token"))
        assertEquals(token, Invitation.parse("wayveil://invite#$token"))
        listOf("http://link.chromvoid.com/#$token", "https://link.chromvoid.com.evil.test/#$token",
            "https://link.chromvoid.com@evil.test/#$token", "https://link.chromvoid.com/admin#$token",
            "https://link.chromvoid.com/?token=$token", "https://link.chromvoid.com/#short").forEach {
            val error = assertThrows(AccessFailure::class.java) { Invitation.parse(it) }
            assertFalse(error.message.orEmpty().contains(token))
        }
    }

    @Test fun pendingEnrollmentPersistsTheSameIdentityAndDropsTheInvitationOnSuccess() {
        val pending = DeviceAccess.pending("invitation")
        val restored = DeviceAccess.parse(pending.toJson())
        assertEquals(pending.installation, restored.installation)
        assertEquals(pending.token, restored.token)
        assertEquals(32, Base64.getUrlDecoder().decode(restored.token).size)
        val enrolled = DeviceAccess.parse(restored.enrolled("device-one").select("node-one").toJson())
        assertEquals("", enrolled.invitation)
        assertEquals("device-one", enrolled.device)
        assertEquals("node-one", enrolled.node)
        assertEquals(pending.token, enrolled.token)
    }

    @Test fun catalogWaitsForAcknowledgementAndDoesNotReplaceAManualNodeSelection() {
        val pending = buildJsonObject { put("id", "pending"); put("name", "Pending"); put("ready", false) }
        val claims = Base64.getUrlEncoder().withoutPadding().encodeToString("{\"exp\":2000000000}".toByteArray())
        val ready = buildJsonObject {
            put("id", "ready"); put("name", "Ready"); put("ready", true)
            put("server", profile.server); put("server_port", profile.port); put("server_name", profile.serverName)
            put("ticket", "header.$claims.signature"); put("obfs_password", profile.obfsPassword); put("certificate", "")
        }
        fun catalog(nodes: List<JsonObject>) = NodeCatalog.parse(buildJsonObject {
            put("grant", buildJsonObject { put("label", "Access"); put("expires_at", 0) }); put("nodes", JsonArray(nodes))
        })
        assertNull(catalog(listOf(pending)).selected(""))
        assertFalse(catalog(listOf(pending)).selected("pending")!!.ready)
        val active = catalog(listOf(pending, ready))
        assertEquals("ready", active.selected("")!!.id)
        assertEquals(2000000000, active.selected("ready")!!.expiresAt)
        assertNull(active.selected("removed"))
    }
}
