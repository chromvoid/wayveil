package app.wayveil

import java.net.IDN
import java.net.URI
import java.util.Locale
import kotlinx.serialization.json.*

class RoutingFailure(val code: String) : Exception(code)

data class RoutingCategory(
    val id: String,
    val title: Map<String, String>,
    val domainSuffix: List<String>,
    val domain: List<String>
)

data class RoutingDocument(val version: Long, val categories: List<RoutingCategory>)

data class RoutingOverrides(val direct: List<String> = emptyList(), val proxy: List<String> = emptyList()) {
    fun toJson(): String = buildJsonObject {
        put("format", 1)
        put("direct", JsonArray(direct.map(::JsonPrimitive)))
        put("proxy", JsonArray(proxy.map(::JsonPrimitive)))
    }.toString()

    fun add(input: String, direct: Boolean): RoutingOverrides {
        val name = RoutingRules.normalizeInput(input)
        val selected = if (direct) this.direct else proxy
        val other = if (direct) proxy else this.direct
        if (name in other) throw RoutingFailure("conflicting_entry")
        if (name in selected) throw RoutingFailure("duplicate_entry")
        if (selected.size >= 500) throw RoutingFailure("too_many_entries")
        return if (direct) copy(direct = selected + name) else copy(proxy = selected + name)
    }

    fun remove(domain: String, direct: Boolean): RoutingOverrides =
        if (direct) copy(direct = this.direct - domain) else copy(proxy = proxy - domain)
}

object RoutingRules {
    const val MAX_DOCUMENT_BYTES = 65536
    private val label = Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
    private val categoryID = Regex("[a-z0-9-]{1,32}")
    private val integer = Regex("-?(?:0|[1-9][0-9]*)")
    private val allowedTLDs = setOf("ru", "su", "xn--p1ai")

    fun parseDocument(text: String): RoutingDocument {
        if (text.toByteArray(Charsets.UTF_8).size > MAX_DOCUMENT_BYTES) fail("too_large")
        val root = document(text, setOf("format", "version", "categories"))
        checkFormat(root)
        val version = number(root["version"])?.takeIf { it > 0 } ?: fail("invalid_version")
        val categories = root["categories"] as? JsonArray ?: fail("invalid_document")
        if (categories.size !in 1..32) fail("invalid_category")
        val ids = mutableSetOf<String>()
        val names = mutableSetOf<String>()
        val parsed = categories.map { item ->
            val category = item as? JsonObject ?: fail("invalid_document")
            checkFields(category, setOf("id", "title", "domain_suffix", "domain"))
            val id = category["id"]?.let(::string) ?: ""
            val title = when (val value = category["title"]) {
                null, JsonNull -> emptyMap()
                is JsonObject -> {
                    checkFields(value, setOf("ru", "en"))
                    value.mapValues { string(it.value) }
                }
                else -> fail("invalid_document")
            }
            val suffixes = strings(category, "domain_suffix", optional = true)
            val domains = strings(category, "domain", optional = true)
            if (!categoryID.matches(id) || !ids.add(id) || title.keys != setOf("ru", "en") ||
                title.values.any { it.codePointCount(0, it.length) !in 1..64 } || suffixes.isEmpty() && domains.isEmpty()) {
                fail("invalid_category")
            }
            for ((entries, suffix) in listOf(suffixes to true, domains to false)) {
                for (name in entries) {
                    validateDomain(name, suffix, allowTLD = true)
                    if (!names.add(name)) fail("duplicate_entry")
                    if (names.size > 3000) fail("too_many_entries")
                }
            }
            RoutingCategory(id, title, suffixes, domains)
        }
        return RoutingDocument(version, parsed)
    }

    fun parseOverrides(text: String): RoutingOverrides {
        val root = document(text, setOf("format", "direct", "proxy"))
        checkFormat(root)
        val direct = strings(root, "direct")
        val proxy = strings(root, "proxy")
        if (direct.size > 500 || proxy.size > 500) fail("too_many_entries")
        val names = mutableSetOf<String>()
        for (name in direct + proxy) {
            validateDomain(name, suffix = true, allowTLD = false)
            if (!names.add(name)) fail("duplicate_entry")
        }
        return RoutingOverrides(direct, proxy)
    }

    fun normalizeInput(text: String): String {
        try {
            val input = text.trim()
            val uri = URI(if (input.contains("://")) input else "https://$input")
            val authority = uri.rawAuthority ?: fail("invalid_domain")
            if (uri.scheme.isNullOrEmpty() || authority.contains('@') || authority.contains('%')) fail("invalid_domain")
            val parts = authority.split(':')
            if (parts.size > 2 || parts.size == 2 && parts[1].toIntOrNull()?.let { it in 1..65535 } != true) fail("invalid_domain")
            val host = parts[0].lowercase(Locale.ROOT).removePrefix("www.")
            val ascii = IDN.toASCII(host, IDN.USE_STD3_ASCII_RULES).lowercase(Locale.ROOT)
            validateDomain(ascii, suffix = true, allowTLD = false)
            return ascii
        } catch (_: Exception) {
            fail("invalid_domain")
        }
    }

    fun merge(mode: RoutingMode, base: RoutingDocument, overrides: RoutingOverrides): JsonObject {
        val suffixes = overrides.direct.toMutableSet()
        val domains = mutableSetOf<String>()
        if (mode == RoutingMode.RUSSIAN_DIRECT) {
            base.categories.forEach { category ->
                suffixes.addAll(category.domainSuffix)
                domains.addAll(category.domain)
            }
        }
        return buildJsonObject {
            put("proxy_suffix", JsonArray(overrides.proxy.distinct().map(::JsonPrimitive)))
            put("direct_suffix", JsonArray(suffixes.map(::JsonPrimitive)))
            put("direct_domain", JsonArray(domains.map(::JsonPrimitive)))
        }
    }

    private fun document(text: String, fields: Set<String>): JsonObject {
        val root = try { Json.parseToJsonElement(text) as? JsonObject ?: fail("invalid_document") }
        catch (_: Exception) { fail("invalid_document") }
        checkFields(root, fields)
        return root
    }

    private fun checkFields(value: JsonObject, fields: Set<String>) {
        if (value.keys.any { it !in fields }) fail("invalid_document")
    }

    private fun number(value: JsonElement?): Long? = (value as? JsonPrimitive)
        ?.takeIf { !it.isString && integer.matches(it.content) }?.content?.toLongOrNull()

    private fun checkFormat(root: JsonObject) {
        val format = number(root["format"]) ?: fail("invalid_document")
        if (format != 1L) fail("format_unsupported")
    }

    private fun string(value: JsonElement): String =
        (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("invalid_document")

    private fun strings(value: JsonObject, key: String, optional: Boolean = false): List<String> {
        val items = value[key] ?: if (optional) return emptyList() else fail("invalid_document")
        return (items as? JsonArray)?.map(::string) ?: fail("invalid_document")
    }

    private fun validateDomain(name: String, suffix: Boolean, allowTLD: Boolean) {
        if (name.length !in 1..253) fail("invalid_domain")
        val labels = name.split('.')
        if (labels.any { !label.matches(it) }) fail("invalid_domain")
        if (labels.size == 4 && labels.all { part ->
                part.toIntOrNull()?.let { it in 0..255 && part == it.toString() } == true
            }) fail("invalid_domain")
        if (labels.size == 1) {
            if (!suffix) fail("invalid_domain")
            if (!allowTLD || name !in allowedTLDs) fail("tld_not_allowed")
        }
    }

    private fun fail(code: String): Nothing = throw RoutingFailure(code)
}
