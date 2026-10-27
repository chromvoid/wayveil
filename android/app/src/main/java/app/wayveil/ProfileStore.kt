package app.wayveil

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

class ProfileStore(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "profile.enc"))
    private val accessFile = AtomicFile(File(context.noBackupFilesDir, "access.enc"))
    private val preferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val savedProfile = MutableStateFlow<ConnectionProfile?>(null)
    val profile = savedProfile.asStateFlow()
    private val savedAccess = MutableStateFlow<DeviceAccess?>(null)
    val access = savedAccess.asStateFlow()
    val mode = MutableStateFlow(RoutingMode.valueOf(preferences.getString("routing", RoutingMode.ALL.name)!!))
    var loadFailed = false
        private set

    init {
        if (file.baseFile.exists()) {
            try {
                savedProfile.value = ConnectionProfile.parse(readEncrypted(file))
            } catch (_: Exception) {
                loadFailed = true
            }
        }
        if (accessFile.baseFile.exists()) {
            try { savedAccess.value = DeviceAccess.parse(readEncrypted(accessFile)) }
            catch (_: Exception) { loadFailed = true }
        }
    }

    fun save(profile: ConnectionProfile) {
        writeEncrypted(file, profile.toJson())
        loadFailed = false
        savedProfile.value = profile
    }

    fun saveAccess(access: DeviceAccess) {
        writeEncrypted(accessFile, access.toJson())
        loadFailed = false
        savedAccess.value = access
    }

    fun removeAccess() {
        accessFile.delete()
        savedAccess.value = null
    }

    private fun readEncrypted(source: AtomicFile): String {
        val bytes = source.readFully()
        require(bytes.size in 29..(ConnectionProfile.MAX_LENGTH * 4))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
    }

    private fun writeEncrypted(target: AtomicFile, text: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val output = target.startWrite()
        try {
            output.write(cipher.iv + cipher.doFinal(text.toByteArray(Charsets.UTF_8)))
            target.finishWrite(output)
        } catch (error: Exception) {
            target.failWrite(output)
            throw error
        }
    }

    fun remove() {
        file.delete()
        savedProfile.value = null
        loadFailed = false
    }

    fun setRoutingMode(value: RoutingMode) {
        preferences.edit().putString("routing", value.name).apply()
        mode.value = value
    }

    fun consentGranted() = preferences.getBoolean("vpn_consent", false)
    fun grantConsent() { preferences.edit().putBoolean("vpn_consent", true).apply() }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("wayveil.profile", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("wayveil.profile", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
}
