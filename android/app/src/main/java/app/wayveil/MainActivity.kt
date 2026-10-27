package app.wayveil

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val profiles get() = (application as WayveilApplication).profiles
    private val access get() = (application as WayveilApplication).access
    private var importing by mutableStateOf(false)
    private var importText by mutableStateOf("")
    private var error by mutableStateOf<String?>(null)
    private var consent by mutableStateOf(false)
    private var saving by mutableStateOf(false)

    private val vpnPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) WayveilVpnService.start(this)
        else error = getString(R.string.permission_denied)
    }
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { prepareVpn() }
    private val scanner = registerForActivityResult(ScanContract()) { result ->
        result.contents?.let { showImport(it) }
    }
    private val document = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) lifecycleScope.launch {
            try {
                val text = withContext(Dispatchers.IO) {
                    contentResolver.openInputStream(uri)!!.bufferedReader().use { reader ->
                        val result = StringBuilder()
                        val buffer = CharArray(4096)
                        while (true) {
                            val count = reader.read(buffer)
                            if (count == -1) break
                            result.append(buffer, 0, count)
                            require(result.length <= ConnectionProfile.MAX_LENGTH)
                        }
                        result.toString()
                    }
                }
                showImport(text)
            } catch (_: Exception) { error = getString(R.string.read_failed) }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        if (profiles.loadFailed) error = getString(R.string.load_failed)
        handleIntent(intent)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                while (true) {
                    if (profiles.access.value != null) refreshCatalog()
                    delay(if (access.state.value.catalog?.nodes?.any { it.ready } == true) 60_000 else 15_000)
                }
            }
        }
        setContent {
            val profile by profiles.profile.collectAsStateWithLifecycle()
            val mode by profiles.mode.collectAsStateWithLifecycle()
            val status by WayveilVpnService.status.collectAsStateWithLifecycle()
            val credentials by profiles.access.collectAsStateWithLifecycle()
            val catalog by access.state.collectAsStateWithLifecycle()
            WayveilTheme {
                WayveilScreen(profile, mode, status, error, credentials, catalog,
                    onConnect = {
                        if (status.running) WayveilVpnService.stop(this)
                        else if (!profiles.consentGranted()) consent = true
                        else requestVpn()
                    },
                    onImport = { showImport("") },
                    onRemove = {
                        if (credentials == null) profiles.remove()
                        else lifecycleScope.launch {
                            try { access.remove() }
                            catch (failure: AccessFailure) { error = getString(failure.messageResource) }
                            catch (failure: CancellationException) { throw failure }
                            catch (_: Exception) { error = getString(R.string.save_failed) }
                        }
                    },
                    onRefresh = { lifecycleScope.launch { refreshCatalog() } },
                    onSelectNode = { id -> lifecycleScope.launch {
                        try { access.select(id) }
                        catch (failure: CancellationException) { throw failure }
                        catch (_: Exception) { error = getString(R.string.save_failed) }
                    } },
                    onRouting = { profiles.setRoutingMode(it) },
                    onDismissError = { error = null; access.clearError(); WayveilVpnService.clearError() })
                if (importing) ImportDialog(importText, saving, error,
                    onText = { importText = it; error = null },
                    onDismiss = { importing = false; importText = ""; error = null },
                    onConfirm = { importProfile() },
                    onFile = { document.launch(arrayOf("application/json", "text/*", "application/octet-stream")) },
                    onScan = {
                        scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                            .setPrompt(getString(R.string.scan_prompt)).setBeepEnabled(false).setOrientationLocked(false))
                    })
                if (consent) ConsentDialog(
                    onDismiss = { consent = false },
                    onAgree = { consent = false; profiles.grantConsent(); requestVpn() })
            }
        }
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handleIntent(intent) }

    private fun handleIntent(value: Intent) {
        when (value.action) {
            Intent.ACTION_VIEW -> value.dataString?.let(::showImport)
            Intent.ACTION_SEND -> value.getStringExtra(Intent.EXTRA_TEXT)?.let(::showImport)
        }
        value.data = null
        value.removeExtra(Intent.EXTRA_TEXT)
    }

    private fun showImport(text: String) {
        if (WayveilVpnService.status.value.running) { error = getString(R.string.disconnect_first); return }
        importText = text.take(ConnectionProfile.MAX_LENGTH + 1)
        importing = true
        error = null
    }

    private fun importProfile() {
        if (saving) return
        lifecycleScope.launch {
            saving = true
            try {
                if (Invitation.isLink(importText)) access.activate(importText)
                else {
                    if (profiles.access.value != null) throw AccessFailure("already_activated")
                    val profile = ConnectionProfile.parse(importText)
                    withContext(Dispatchers.IO) { profiles.save(profile) }
                }
                importText = ""; importing = false; error = null
            } catch (failure: AccessFailure) {
                error = getString(failure.messageResource)
                if (profiles.access.value?.device?.isNotEmpty() == true) { importText = ""; importing = false }
            } catch (failure: ProfileError) { error = failure.message }
            catch (failure: CancellationException) { throw failure }
            catch (_: Exception) { error = getString(R.string.save_failed) }
            finally { saving = false }
        }
    }

    private suspend fun refreshCatalog() {
        try { access.refresh() }
        catch (_: AccessFailure) { }
    }

    private fun requestVpn() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else prepareVpn()
    }

    private fun prepareVpn() {
        val permission = VpnService.prepare(this)
        if (permission != null) vpnPermission.launch(permission) else WayveilVpnService.start(this)
    }
}
