package app.wayveil

import android.content.Context
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import kotlinx.serialization.json.JsonObject

class RoutingRulesStore internal constructor(
    bundled: String,
    readCache: () -> String?,
    private val writeCache: (String) -> Unit,
    readOverrides: () -> String?,
    private val writeOverrides: (String) -> Unit,
) {
    private var current = RoutingRules.parseDocument(bundled)
    private var personal = RoutingOverrides()
    @Volatile
    var overridesError: Exception? = null
        private set

    init {
        try {
            readCache()?.let { text ->
                val cached = RoutingRules.parseDocument(text)
                if (cached.version > current.version) current = cached
            }
        } catch (_: Exception) { /* Keep the bundled rules when the cache is unreadable. */ }
        try { readOverrides()?.let { personal = RoutingRules.parseOverrides(it) } }
        catch (error: Exception) { overridesError = error }
    }

    @Synchronized fun base(): RoutingDocument = current

    @Synchronized fun overrides(): RoutingOverrides = personal

    @Synchronized fun rules(mode: RoutingMode): JsonObject = RoutingRules.merge(mode, current, personal)

    @Synchronized fun accept(text: String): Boolean {
        val candidate = RoutingRules.parseDocument(text)
        if (candidate.version <= current.version) return false
        writeCache(text)
        current = candidate
        return true
    }

    @Synchronized fun add(input: String, direct: Boolean) {
        saveOverrides(personal.add(input, direct))
    }

    @Synchronized fun remove(domain: String, direct: Boolean) {
        saveOverrides(personal.remove(domain, direct))
    }

    private fun saveOverrides(value: RoutingOverrides) {
        writeOverrides(value.toJson())
        personal = value
        overridesError = null
    }

    companion object {
        fun create(context: Context, profiles: ProfileStore): RoutingRulesStore {
            val cache = AtomicFile(File(context.noBackupFilesDir, "routing-rules.json"))
            val overrides = AtomicFile(File(context.noBackupFilesDir, "routing-overrides.enc"))
            return RoutingRulesStore(
                bundled = context.assets.open("default-rules.json").bufferedReader(Charsets.UTF_8).use { it.readText() },
                readCache = {
                    try {
                        cache.openRead().use { input ->
                            if (input.channel.size() > RoutingRules.MAX_DOCUMENT_BYTES) throw RoutingFailure("too_large")
                            val bytes = input.readBytes()
                            if (bytes.size > RoutingRules.MAX_DOCUMENT_BYTES) throw RoutingFailure("too_large")
                            bytes.decodeToString(throwOnInvalidSequence = true)
                        }
                    } catch (_: FileNotFoundException) { null }
                },
                writeCache = { text ->
                    val output = cache.startWrite()
                    try {
                        output.write(text.toByteArray(Charsets.UTF_8))
                        cache.finishWrite(output)
                    } catch (error: Exception) {
                        cache.failWrite(output)
                        throw error
                    }
                },
                readOverrides = {
                    try { profiles.readEncrypted(overrides) }
                    catch (_: FileNotFoundException) { null }
                },
                writeOverrides = { profiles.writeEncrypted(overrides, it) },
            )
        }
    }
}
