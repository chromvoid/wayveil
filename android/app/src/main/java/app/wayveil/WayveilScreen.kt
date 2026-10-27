package app.wayveil

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chromvoid.core.mobile.Mobile

private val Mint = Color(0xFFB6F0C8)
private val Background = Color(0xFF0C171C)
private val Panel = Color(0xFF15262D)
private val Muted = Color(0xFF9AAFB6)

@Composable
fun WayveilTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = darkColorScheme(
        primary = Mint, onPrimary = Color(0xFF123025), background = Background,
        surface = Panel, surfaceVariant = Color(0xFF20353D), onSurface = Color(0xFFEDF4F3),
        onSurfaceVariant = Muted, outline = Color(0xFF36515A), error = Color(0xFFFFB4AB),
    ), content = content)
}

@Composable
fun WayveilScreen(
    profile: ConnectionProfile?, mode: RoutingMode, status: TunnelStatus, error: String?,
    access: DeviceAccess?, catalog: AccessState,
    onConnect: () -> Unit, onImport: () -> Unit, onRemove: () -> Unit,
    onRefresh: () -> Unit, onSelectNode: (String) -> Unit,
    onRouting: (RoutingMode) -> Unit, onDismissError: () -> Unit,
) {
    var about by remember { mutableStateOf(false) }
    var remove by remember { mutableStateOf(false) }
    val statusText = when (status.phase) {
        TunnelPhase.DISCONNECTED -> R.string.disconnected
        TunnelPhase.CONNECTING -> R.string.connecting
        TunnelPhase.CONNECTED -> R.string.connected
        TunnelPhase.RECONNECTING -> R.string.reconnecting
        TunnelPhase.STOPPING -> R.string.stopping
        TunnelPhase.ERROR -> R.string.connection_error
    }
    Surface(color = Background, modifier = Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF142E36), Background), endY = 1000f))
            .safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 520.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 18.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.app_name), fontSize = 29.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-1).sp, modifier = Modifier.weight(1f))
                    IconButton(onClick = { about = true }) { Icon(Icons.Default.Info, stringResource(R.string.about), tint = Muted) }
                }
                Spacer(Modifier.height(26.dp))
                Text(stringResource(R.string.tagline), fontSize = 11.sp, color = Mint, fontWeight = FontWeight.Bold, letterSpacing = 2.sp, textAlign = TextAlign.Center)
                Spacer(Modifier.height(10.dp))
                Text(stringResource(R.string.subtitle), color = Muted, fontSize = 15.sp, textAlign = TextAlign.Center)
                Spacer(Modifier.height(27.dp))
                Surface(color = if (status.phase == TunnelPhase.CONNECTED) Mint.copy(alpha = .12f) else Panel, shape = CircleShape) {
                    Row(Modifier.padding(horizontal = 16.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(7.dp).background(if (status.phase == TunnelPhase.CONNECTED) Mint else Muted, CircleShape))
                        Spacer(Modifier.width(9.dp))
                        Text(stringResource(statusText), fontSize = 13.sp, color = if (status.phase == TunnelPhase.CONNECTED) Mint else Muted)
                    }
                }
                Spacer(Modifier.height(26.dp))
                val managedReady = catalog.catalog?.selected(access?.node.orEmpty())?.ready == true &&
                    catalog.error?.let { AccessFailure(it).terminal } != true
                val needsProfile = profile == null && access == null
                PortalButton(status.phase, status.running || access == null || managedReady) {
                    if (!status.running && needsProfile) onImport() else onConnect()
                }
                Spacer(Modifier.height(18.dp))
                Text(stringResource(when (status.phase) {
                    TunnelPhase.CONNECTED -> R.string.connected_hint
                    TunnelPhase.CONNECTING -> R.string.connecting_hint
                    TunnelPhase.RECONNECTING -> R.string.reconnecting_hint
                    else -> if (access != null && !managedReady) R.string.access_activating else if (profile == null && access == null) R.string.empty_hint else R.string.ready_hint
                }), color = Muted, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.widthIn(max = 330.dp))
                Spacer(Modifier.height(28.dp))
                val visibleError = error ?: status.error ?: catalog.error?.let { stringResource(AccessFailure(it).messageResource) }
                if (visibleError != null) {
                    Surface(color = MaterialTheme.colorScheme.errorContainer.copy(alpha = .5f), shape = RoundedCornerShape(18.dp)) {
                        Row(Modifier.padding(start = 16.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(visibleError, modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
                            IconButton(onClick = onDismissError) { Icon(Icons.Default.Close, stringResource(R.string.dismiss_error)) }
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                }
                Surface(shape = RoundedCornerShape(24.dp), color = Panel, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(20.dp)) {
                        SectionLabel(stringResource(if (access == null) R.string.profile else R.string.node_catalog))
                        Spacer(Modifier.height(14.dp))
                        if (access != null) {
                            Text(catalog.catalog?.label ?: stringResource(R.string.access_activating), style = MaterialTheme.typography.titleMedium)
                            catalog.catalog?.expiresAt?.takeIf { it > 0 }?.let {
                                Text(stringResource(R.string.access_valid_until, java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it * 1000))),
                                    color = Muted, style = MaterialTheme.typography.bodySmall)
                            }
                            if (catalog.catalog?.nodes.isNullOrEmpty()) {
                                Text(stringResource(R.string.no_nodes), color = Muted, style = MaterialTheme.typography.bodyMedium)
                            }
                            catalog.catalog?.nodes?.forEach { node ->
                                val selectable = node.ready && !status.running && !catalog.loading
                                Row(Modifier.fillMaxWidth().selectable(access.node == node.id, enabled = selectable,
                                    role = Role.RadioButton, onClick = { onSelectNode(node.id) }).padding(vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically) {
                                    RadioButton(access.node == node.id, onClick = null, enabled = selectable)
                                    Column(Modifier.weight(1f)) {
                                        Text(node.name, style = MaterialTheme.typography.bodyLarge)
                                        if (!node.ready) Text(stringResource(R.string.access_activating), color = Muted, style = MaterialTheme.typography.bodySmall)
                                    }
                                }
                            }
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                TextButton(onClick = onRefresh, enabled = !catalog.loading) { Text(stringResource(if (catalog.loading) R.string.catalog_refreshing else R.string.refresh_catalog)) }
                                IconButton(onClick = { remove = true }, enabled = !status.running && !catalog.loading) {
                                    Icon(Icons.Default.Delete, stringResource(R.string.remove_access), tint = Muted)
                                }
                            }
                        } else if (profile == null) {
                            Text(stringResource(R.string.empty_title), style = MaterialTheme.typography.titleMedium)
                        } else {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(profile.name, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    Spacer(Modifier.height(5.dp))
                                    Text(profile.server, color = Muted, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                IconButton(onClick = { remove = true }, enabled = !status.running) {
                                    Icon(Icons.Default.Delete, stringResource(R.string.remove_profile), tint = Muted)
                                }
                            }
                        }
                        if (access == null) {
                            Spacer(Modifier.height(14.dp))
                            OutlinedButton(onClick = onImport, enabled = !status.running, modifier = Modifier.fillMaxWidth()) {
                                Icon(Icons.Default.Add, null, Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(stringResource(if (profile == null) R.string.add_profile else R.string.replace_profile))
                            }
                        }
                    }
                }
                Spacer(Modifier.height(16.dp))
                Surface(shape = RoundedCornerShape(24.dp), color = Panel, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(top = 20.dp, bottom = 12.dp)) {
                        SectionLabel(stringResource(R.string.routing), Modifier.padding(horizontal = 20.dp))
                        Spacer(Modifier.height(10.dp))
                        RoutingMode.entries.forEach { value ->
                            Row(Modifier.fillMaxWidth().selectable(mode == value, enabled = !status.running,
                                role = Role.RadioButton, onClick = { onRouting(value) }).padding(horizontal = 12.dp, vertical = 2.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                RadioButton(selected = mode == value, onClick = null, enabled = !status.running)
                                Text(stringResource(if (value == RoutingMode.ALL) R.string.route_all else R.string.route_ru),
                                    style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(start = 10.dp, top = 12.dp, bottom = 12.dp))
                            }
                        }
                        Text(stringResource(if (mode == RoutingMode.ALL) R.string.route_all_hint else R.string.route_ru_hint),
                            color = Muted, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp))
                        if (status.running) Text(stringResource(R.string.edit_disconnected), color = Mint.copy(alpha = .7f),
                            style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp))
                    }
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }
    if (about) AboutDialog { about = false }
    if (remove) AlertDialog(onDismissRequest = { remove = false },
        title = { Text(stringResource(if (access == null) R.string.remove_profile else R.string.remove_access)) },
        text = { Text(stringResource(if (access == null) R.string.remove_confirm else R.string.remove_access_confirm)) },
        confirmButton = { TextButton(onClick = { onRemove(); remove = false }) { Text(stringResource(R.string.remove)) } },
        dismissButton = { TextButton(onClick = { remove = false }) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun PortalButton(phase: TunnelPhase, enabled: Boolean, onClick: () -> Unit) {
    val connected = phase == TunnelPhase.CONNECTED
    val running = phase !in setOf(TunnelPhase.DISCONNECTED, TunnelPhase.ERROR)
    var stageCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var logoCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var logoBounds by remember { mutableStateOf(Rect.Zero) }
    fun updateLogoBounds() {
        val stage = stageCoordinates
        val logo = logoCoordinates
        if (stage != null && stage.isAttached && logo != null && logo.isAttached) {
            logoBounds = stage.localBoundingBoxOf(logo, clipBounds = false)
        }
    }
    BoxWithConstraints(Modifier.widthIn(max = 292.dp).fillMaxWidth().aspectRatio(1f)
        .onGloballyPositioned { stageCoordinates = it; updateLogoBounds() }, contentAlignment = Alignment.Center) {
        val diameter = minOf(164.dp, maxWidth * .6f)
        PortalEffect(phase, diameter, logoBounds, Modifier.matchParentSize())
        Surface(onClick = onClick, enabled = enabled && phase != TunnelPhase.STOPPING,
            modifier = Modifier.size(diameter), shape = CircleShape,
            color = Color.Transparent, contentColor = Mint,
            border = BorderStroke(1.dp, Mint.copy(alpha = if (connected) .29f else .12f))) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Spacer(Modifier.size(diameter * .38f).onGloballyPositioned { logoCoordinates = it; updateLogoBounds() })
                Spacer(Modifier.height(8.dp))
                Text(stringResource(if (running) R.string.disconnect else R.string.connect),
                    style = MaterialTheme.typography.labelLarge, textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 12.dp))
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier, color = Muted, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.3.sp)
}

@Composable
fun ImportDialog(text: String, saving: Boolean, error: String?, onText: (String) -> Unit,
    onDismiss: () -> Unit, onConfirm: () -> Unit, onFile: () -> Unit, onScan: () -> Unit) {
    val uriHandler = LocalUriHandler.current
    AlertDialog(onDismissRequest = { if (!saving) onDismiss() },
        title = { Text(stringResource(R.string.import_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(stringResource(R.string.import_hint), color = Muted)
                Spacer(Modifier.height(18.dp))
                OutlinedTextField(text, onValueChange = { if (it.length <= ConnectionProfile.MAX_LENGTH) onText(it) },
                    label = { Text(stringResource(R.string.profile_input)) },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password),
                    enabled = !saving, minLines = 2, maxLines = 4, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(10.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = onScan, enabled = !saving) { Text(stringResource(R.string.scan_qr)) }
                    TextButton(onClick = onFile, enabled = !saving) { Text(stringResource(R.string.open_file)) }
                }
                if (Invitation.isLink(text)) {
                    Text(stringResource(R.string.activation_disclosure), style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = { uriHandler.openUri("https://link.chromvoid.com/privacy") }) {
                        Text(stringResource(R.string.privacy_policy))
                    }
                }
                if (error != null) Text(error, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = { TextButton(onClick = onConfirm, enabled = text.isNotBlank() && !saving) { Text(stringResource(if (Invitation.isLink(text)) R.string.activate_device else R.string.import_profile)) } },
        dismissButton = { TextButton(onClick = onDismiss, enabled = !saving) { Text(stringResource(R.string.cancel)) } })
}

@Composable
fun ConsentDialog(onDismiss: () -> Unit, onAgree: () -> Unit) {
    val uriHandler = LocalUriHandler.current
    AlertDialog(onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.consent_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(stringResource(R.string.consent_body))
                TextButton(onClick = { uriHandler.openUri("https://link.chromvoid.com/privacy") }) {
                    Text(stringResource(R.string.privacy_policy))
                }
            }
        },
        confirmButton = { TextButton(onClick = onAgree) { Text(stringResource(R.string.agree_connect)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun AboutDialog(onDismiss: () -> Unit) {
    var licenses by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    val licenseText = remember { context.assets.open("LICENSES.txt").bufferedReader().use { it.readText() } }
    AlertDialog(onDismissRequest = onDismiss,
        icon = { Icon(painterResource(R.drawable.ic_portal), null, Modifier.size(40.dp), tint = Mint) },
        title = { Text(stringResource(if (licenses) R.string.licenses else R.string.about)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(if (licenses) licenseText else stringResource(R.string.about_body, BuildConfig.VERSION_NAME, Mobile.version()),
                    style = MaterialTheme.typography.bodyMedium)
                if (!licenses) {
                    TextButton(onClick = { uriHandler.openUri("https://link.chromvoid.com/privacy") }) {
                        Text(stringResource(R.string.privacy_policy))
                    }
                    TextButton(onClick = { uriHandler.openUri("https://link.chromvoid.com/support") }) {
                        Text(stringResource(R.string.support))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
        dismissButton = { if (!licenses) TextButton(onClick = { licenses = true }) { Text(stringResource(R.string.licenses)) } })
}
