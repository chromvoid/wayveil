package app.wayveil

import java.io.File
import java.io.IOException
import java.util.Base64
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ConnectionProfileTest {
    private val profile = ConnectionProfile("Personal server", "vpn.example.com", 46219, "secret@+:/", "obfs-secret", "vpn.example.com", "")

    private val routingFixtures get() = File(checkNotNull(System.getProperty("routingTestdataDir")))

    @Test fun validatesAllSharedRoutingDocuments() {
        validateRoutingFixtures("documents", RoutingRules::parseDocument)
    }

    @Test fun validatesAllSharedRoutingOverrides() {
        validateRoutingFixtures("overrides", RoutingRules::parseOverrides)
    }

    private fun validateRoutingFixtures(directory: String, parse: (String) -> Any) {
        for (valid in listOf(true, false)) {
            val files = checkNotNull(File(routingFixtures, "$directory/${if (valid) "valid" else "invalid"}").listFiles())
                .filter { it.extension == "json" }
            assertTrue("Missing routing fixtures: $directory", files.isNotEmpty())
            files.forEach { file ->
                if (valid) parse(file.readText(Charsets.UTF_8))
                else {
                    val failure = assertThrows(file.name, RoutingFailure::class.java) { parse(file.readText(Charsets.UTF_8)) }
                    assertEquals(file.name, File(file.parentFile, "${file.nameWithoutExtension}.error").readText().trim(), failure.code)
                }
            }
        }
    }

    @Test fun normalizesAllSharedRoutingInputs() {
        Json.parseToJsonElement(File(routingFixtures, "input.json").readText()).jsonArray.forEach { item ->
            val fixture = item.jsonObject
            val name = fixture.getValue("name").jsonPrimitive.content
            val input = fixture.getValue("input").jsonPrimitive.content
            val expected = fixture.getValue("expected")
            if (expected == JsonNull) {
                val failure = assertThrows(name, RoutingFailure::class.java) { RoutingRules.normalizeInput(input) }
                assertEquals(name, "invalid_domain", failure.code)
            } else assertEquals(name, expected.jsonPrimitive.content, RoutingRules.normalizeInput(input))
        }
    }

    @Test fun mergesAllSharedRoutingRules() {
        Json.parseToJsonElement(File(routingFixtures, "merge.json").readText()).jsonArray.forEach { item ->
            val fixture = item.jsonObject
            val actual = RoutingRules.merge(
                RoutingMode.valueOf(fixture.getValue("routing").jsonPrimitive.content),
                RoutingRules.parseDocument(fixture.getValue("base").toString()),
                RoutingRules.parseOverrides(fixture.getValue("overrides").toString())
            )
            val expected = fixture.getValue("expected").jsonObject
            assertEquals(expected.keys, actual.keys)
            expected.forEach { (key, entries) ->
                assertEquals(fixture.getValue("name").jsonPrimitive.content, entries.jsonArray.toSet(), actual.getValue(key).jsonArray.toSet())
                assertEquals(actual.getValue(key).jsonArray.toSet().size, actual.getValue(key).jsonArray.size)
            }
        }
    }

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
        val base = RoutingRules.parseDocument(File(System.getProperty("routingDefaultRulesFile")).readText())
        for (mode in RoutingMode.entries) {
            val rules = RoutingRules.merge(mode, base, RoutingOverrides())
            val config = Json.parseToJsonElement(TunnelConfig.create(profile, mode, rules)).jsonObject
            assertEquals(Json.parseToJsonElement(profile.toJson()), config.getValue("profile"))
            assertEquals(mode.name, config.getValue("routing").jsonPrimitive.content)
            assertEquals(setOf("profile", "routing", "rules"), config.keys)
            assertEquals(rules, config.getValue("rules"))
            assertTrue(rules.getValue("proxy_suffix").jsonArray.isEmpty())
            assertTrue(rules.getValue("direct_domain").jsonArray.isEmpty())
            if (mode == RoutingMode.ALL) assertTrue(rules.getValue("direct_suffix").jsonArray.isEmpty())
            else assertEquals(setOf("ru", "su", "xn--p1ai", "yandex.net", "yastatic.net", "vk.com", "userapi.com"),
                rules.getValue("direct_suffix").jsonArray.map { it.jsonPrimitive.content }.toSet())
            val personal = RoutingRules.merge(mode, base, RoutingOverrides(direct = listOf("bank.example")))
            val personalConfig = Json.parseToJsonElement(TunnelConfig.create(profile, mode, personal)).jsonObject
            assertTrue(JsonPrimitive("bank.example") in personalConfig.getValue("rules").jsonObject.getValue("direct_suffix").jsonArray)
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

    private val bundledRoutingRules = File(System.getProperty("routingDefaultRulesFile")).readText()

    private fun routingDocument(version: Long) = JsonObject(Json.parseToJsonElement(bundledRoutingRules).jsonObject + ("version" to JsonPrimitive(version)))
    private fun routingCatalog(version: Long) = buildJsonObject { put("routing_rules_version", version) }

    @Test fun routingRefreshAcceptsANewerValidListWithTheCatalogToken() {
        var cache: String? = null
        var writes = 0
        val store = RoutingRulesStore(bundledRoutingRules, { cache }, { cache = it; writes++ }, { null }, {})
        val received = mutableListOf<List<String>>()
        val replacement = routingDocument(2)

        refreshRoutingRules(routingCatalog(2), "device-token", store.base().version, { method, path, token ->
            received += listOf(method, path, token)
            replacement
        }, store::accept)

        assertEquals(listOf(listOf("GET", "/v1/routing-rules", "device-token")), received)
        assertEquals(2L, store.base().version)
        assertEquals(replacement.toString(), cache)
        assertEquals(1, writes)
    }

    @Test fun failedOrStaleRoutingResponsesLeaveTheWorkingCacheUntouched() {
        val responses: List<() -> JsonObject> = listOf(
            { JsonObject(routingDocument(3) + ("categories" to JsonArray(emptyList()))) },
            { routingDocument(2) },
            { routingDocument(1) },
            { Json.parseToJsonElement("{").jsonObject },
            { throw AccessFailure("access_revoked") },
            { throw AccessFailure("internal_error") },
            { throw IOException("Network unavailable") },
        )
        responses.forEachIndexed { index, response ->
            val original = routingDocument(2).toString()
            var cache: String? = original
            var writes = 0
            val store = RoutingRulesStore(bundledRoutingRules, { cache }, { cache = it; writes++ }, { null }, {})

            refreshRoutingRules(routingCatalog(3), "device-token", store.base().version, { _, _, _ -> response() }, store::accept)

            assertEquals("response $index", 2L, store.base().version)
            assertEquals("response $index", original, cache)
            assertEquals("response $index", 0, writes)
        }
    }

    @Test fun routingRefreshOnlyDownloadsWhenTheCatalogAdvertisesANewerVersion() {
        val store = RoutingRulesStore(bundledRoutingRules, { null }, {}, { null }, {})
        listOf(buildJsonObject {}, routingCatalog(1), routingCatalog(0)).forEach { result ->
            refreshRoutingRules(result, "device-token", store.base().version, { _, _, _ ->
                fail("No routing download was expected")
                routingDocument(2)
            }, store::accept)
        }
    }

    @Test fun routingCacheChoosesTheNewestValidSupportedDocument() {
        val cases = listOf(
            Triple(routingDocument(3).toString(), routingDocument(2).toString(), 3L),
            Triple(bundledRoutingRules, routingDocument(3).toString(), 3L),
            Triple(bundledRoutingRules, "{", 1L),
            Triple(bundledRoutingRules, JsonObject(routingDocument(9) + ("format" to JsonPrimitive(2))).toString(), 1L),
        )
        cases.forEach { (builtIn, cache, expected) ->
            val store = RoutingRulesStore(builtIn, { cache }, { fail("Loading must not replace the cache") }, { null }, {})
            assertEquals(expected, store.base().version)
        }
    }

    @Test fun damagedOverridesStayInactiveUntilASuccessfulEdit() {
        val reads: List<() -> String?> = listOf({ "{" }, { throw IOException("Cannot decrypt overrides") })
        reads.forEach { read ->
            var saved: String? = null
            val store = RoutingRulesStore(bundledRoutingRules, { null }, {}, read, { saved = it })
            assertEquals(RoutingOverrides(), store.overrides())
            assertNotNull(store.overridesError)
            assertTrue(store.rules(RoutingMode.ALL).values.all { it.jsonArray.isEmpty() })
            assertEquals(7, store.rules(RoutingMode.RUSSIAN_DIRECT).getValue("direct_suffix").jsonArray.size)

            store.add("https://www.Gosuslugi.ru/help", direct = true)

            assertNull(store.overridesError)
            assertEquals(RoutingOverrides(direct = listOf("gosuslugi.ru")), store.overrides())
            assertEquals(store.overrides(), RoutingRules.parseOverrides(checkNotNull(saved)))
        }
    }

    @Test fun routingEditingErrorsUseTheExpectedMessageResources() {
        val resources = mapOf(
            "invalid_domain" to R.string.routing_invalid_domain,
            "tld_not_allowed" to R.string.routing_invalid_domain,
            "unexpected_parse_error" to R.string.routing_invalid_domain,
            "conflicting_entry" to R.string.routing_conflicting_entry,
            "duplicate_entry" to R.string.routing_duplicate_entry,
            "too_many_entries" to R.string.routing_too_many_entries,
        )
        resources.forEach { (code, resource) ->
            assertEquals(code, resource, RoutingFailure(code).routingMessageResource)
        }
        assertEquals(R.string.routing_save_failed, IOException("Cannot write overrides").routingMessageResource)
    }

    @Test fun overrideEditingPersistsNormalizedNamesAndReportsDistinctErrors() {
        var saved: String? = null
        val store = RoutingRulesStore(bundledRoutingRules, { null }, {}, { saved }, { saved = it })
        val host = "xn--e1afmkfd.xn--p1ai"
        store.add("https://www.ПРИМЕР.РФ:443/help", direct = true)
        assertEquals(listOf(host), store.overrides().direct)
        assertEquals(store.overrides(), RoutingRules.parseOverrides(checkNotNull(saved)))
        assertEquals("duplicate_entry", assertThrows(RoutingFailure::class.java) { store.add(host, direct = true) }.code)
        assertEquals("conflicting_entry", assertThrows(RoutingFailure::class.java) { store.add(host, direct = false) }.code)
        assertEquals("invalid_domain", assertThrows(RoutingFailure::class.java) { store.add("not a domain", direct = true) }.code)
        store.remove(host, direct = true)
        assertEquals(RoutingOverrides(), RoutingRules.parseOverrides(checkNotNull(saved)))

        val full = RoutingOverrides(direct = (1..500).map { "entry$it.example" }).toJson()
        val limited = RoutingRulesStore(bundledRoutingRules, { null }, {}, { full }, { fail("An over-limit edit must not be saved") })
        assertEquals("too_many_entries", assertThrows(RoutingFailure::class.java) { limited.add("extra.example", direct = true) }.code)
        assertEquals(500, limited.overrides().direct.size)
    }
}
