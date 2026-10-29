package app.wayveil

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.chromvoid.core.mobile.Mobile
import kotlinx.coroutines.launch

private val Cyan = Color(0xFF84D5FF)
private val Background = Color(0xFF0B0D10)
private val Panel = Color(0xFF141B22)
private val Backdrop = PortalBackdrop(Color(0xFF0E2D3B), Background, endY = 1000f)
private val Muted = Color(0xFFA5B4C2)

@Composable
fun WayveilTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = darkColorScheme(
        primary = Cyan, onPrimary = Color(0xFF072C3C), background = Background,
        surface = Panel, surfaceVariant = Color(0xFF1E2933), onSurface = Color(0xFFEDF3F8),
        onSurfaceVariant = Muted, outline = Color(0xFF2C3B47), error = Color(0xFFFFB4AB),
    ), content = content)
}

@Composable
fun WayveilScreen(
    profile: ConnectionProfile?, mode: RoutingMode, status: TunnelStatus, error: String?,
    access: DeviceAccess?, catalog: AccessState,
    overrides: RoutingOverrides, overridesDamaged: Boolean, savingOverrides: Boolean,
    onAddException: suspend (String, Boolean) -> Int?, onRemoveException: suspend (String, Boolean) -> Int?,
    onConnect: () -> Unit, onPaste: () -> Unit, onScan: () -> Unit, onFile: () -> Unit, onRemove: () -> Unit,
    onRefresh: () -> Unit, onSelectNode: (String) -> Unit,
    onRouting: (RoutingMode) -> Unit, onDismissError: () -> Unit,
) {
    var about by remember { mutableStateOf(false) }
    var remove by remember { mutableStateOf(false) }
    var exceptions by rememberSaveable { mutableStateOf(false) }
    var connection by rememberSaveable { mutableStateOf(false) }
    var routing by rememberSaveable { mutableStateOf(false) }
    val statusText = when (status.phase) {
        TunnelPhase.DISCONNECTED -> R.string.disconnected
        TunnelPhase.CONNECTING -> R.string.connecting
        TunnelPhase.CONNECTED -> R.string.connected
        TunnelPhase.RECONNECTING -> R.string.reconnecting
        TunnelPhase.STOPPING -> R.string.stopping
        TunnelPhase.ERROR -> R.string.connection_error
    }
    Surface(color = Background, modifier = Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(Backdrop.brush)
            .safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 520.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 18.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.app_name), fontSize = 29.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-1).sp, modifier = Modifier.weight(1f))
                    IconButton(onClick = { about = true }) { Icon(Icons.Default.Info, stringResource(R.string.about), tint = Muted) }
                }
                Spacer(Modifier.height(12.dp))
                val managedReady = catalog.catalog?.selected(access?.node.orEmpty())?.ready == true &&
                    catalog.error?.let { AccessFailure(it).terminal } != true
                val needsProfile = profile == null && access == null
                PortalButton(status.phase, stringResource(statusText), status.running || access == null || managedReady) {
                    if (!status.running && needsProfile) connection = true else onConnect()
                }
                // Always one line, so the rows below never move when the phase changes.
                val line = if (!status.running && access != null && !managedReady) R.string.waiting_server else statusText
                Spacer(Modifier.height(18.dp))
                Crossfade(line, label = "status") {
                    Text(stringResource(it), color = Muted, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 330.dp))
                }
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
                val node = catalog.catalog?.selected(access?.node.orEmpty())
                SummaryRow(R.drawable.ic_server,
                    title = when {
                        access != null -> node?.name ?: catalog.catalog?.label ?: stringResource(R.string.connection_title)
                        profile != null -> profile.name
                        else -> stringResource(R.string.add_profile)
                    },
                    subtitle = when {
                        access != null -> if (node != null) catalog.catalog?.label else null
                        profile != null -> stringResource(R.string.own_profile)
                        else -> stringResource(R.string.add_profile_hint)
                    }) { connection = true }
                Spacer(Modifier.height(10.dp))
                val exceptionCount = overrides.direct.size + overrides.proxy.size
                SummaryRow(R.drawable.ic_route,
                    title = stringResource(if (mode == RoutingMode.ALL) R.string.route_all else R.string.route_ru),
                    subtitle = if (exceptionCount > 0) stringResource(R.string.routing_exceptions_count, exceptionCount) else null) { routing = true }
                Spacer(Modifier.height(24.dp))
            }
        }
    }
    if (connection) ConnectionSheet(profile, access, catalog, status.running, onSelectNode, onRefresh,
        onRemove = { remove = true },
        onPaste = { connection = false; onPaste() }, onScan = { connection = false; onScan() }, onFile = { connection = false; onFile() },
        onDismiss = { connection = false })
    if (routing) RoutingSheet(mode, status.running, onRouting, onExceptions = { exceptions = true }, onDismiss = { routing = false })
    if (about) AboutDialog { about = false }
    if (exceptions) ExceptionsDialog(overrides, overridesDamaged, status.running, savingOverrides,
        onAddException, onRemoveException, onDismiss = { exceptions = false })
    if (remove) AlertDialog(onDismissRequest = { remove = false },
        title = { Text(stringResource(if (access == null) R.string.remove_profile else R.string.remove_access)) },
        text = { Text(stringResource(if (access == null) R.string.remove_confirm else R.string.remove_access_confirm)) },
        confirmButton = { TextButton(onClick = { onRemove(); remove = false }) { Text(stringResource(R.string.remove)) } },
        dismissButton = { TextButton(onClick = { remove = false }) { Text(stringResource(R.string.cancel)) } })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectionSheet(
    profile: ConnectionProfile?, access: DeviceAccess?, catalog: AccessState, running: Boolean,
    onSelectNode: (String) -> Unit, onRefresh: () -> Unit, onRemove: () -> Unit,
    onPaste: () -> Unit, onScan: () -> Unit, onFile: () -> Unit, onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Background) {
        Column(Modifier.widthIn(max = 520.dp).fillMaxWidth().align(Alignment.CenterHorizontally).verticalScroll(rememberScrollState())
            .padding(start = 20.dp, end = 20.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.connection_title), style = MaterialTheme.typography.titleLarge)
            if (access != null) {
                val info = catalog.catalog
                SectionLabel((info?.label ?: stringResource(R.string.node_catalog)).uppercase(), Modifier.padding(top = 10.dp))
                info?.expiresAt?.takeIf { it > 0 }?.let {
                    Text(stringResource(R.string.access_valid_until, java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it * 1000))),
                        color = Muted, style = MaterialTheme.typography.bodySmall)
                }
                if (info?.nodes.isNullOrEmpty()) Text(stringResource(R.string.no_nodes), color = Muted, style = MaterialTheme.typography.bodyMedium)
                info?.nodes?.forEach { node ->
                    val selected = access.node == node.id
                    OptionRow(Modifier.selectable(selected, enabled = node.ready && !running && !catalog.loading,
                        role = Role.RadioButton, onClick = { onSelectNode(node.id) }), selected) {
                        Column(Modifier.weight(1f)) {
                            Text(node.name, style = MaterialTheme.typography.bodyLarge)
                            if (!node.ready) Text(stringResource(R.string.access_activating), color = Muted, style = MaterialTheme.typography.bodySmall)
                        }
                        if (selected) Icon(Icons.Default.Check, null, tint = Cyan)
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton(onClick = onRefresh, enabled = !catalog.loading) {
                        Text(stringResource(if (catalog.loading) R.string.catalog_refreshing else R.string.refresh_catalog))
                    }
                    TextButton(onClick = onRemove, enabled = !running && !catalog.loading) {
                        Text(stringResource(R.string.remove_access), color = Muted)
                    }
                }
            } else {
                if (profile != null) {
                    SectionLabel(stringResource(R.string.profile), Modifier.padding(top = 10.dp))
                    OptionRow(Modifier, selected = true) {
                        Column(Modifier.weight(1f)) {
                            Text(profile.name, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Text(profile.server, color = Muted, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        IconButton(onClick = onRemove, enabled = !running) {
                            Icon(Icons.Default.Delete, stringResource(R.string.remove_profile), tint = Muted)
                        }
                    }
                }
                SectionLabel(stringResource(if (profile == null) R.string.add_profile else R.string.replace_profile).uppercase(),
                    Modifier.padding(top = 10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SourceButton(R.drawable.ic_paste, R.string.source_paste, !running, onPaste)
                    SourceButton(R.drawable.ic_qr, R.string.source_qr, !running, onScan)
                    SourceButton(R.drawable.ic_file, R.string.source_file, !running, onFile)
                }
            }
            if (running) Text(stringResource(R.string.edit_disconnected), color = Cyan.copy(alpha = .7f), style = MaterialTheme.typography.bodySmall)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RoutingSheet(mode: RoutingMode, running: Boolean, onRouting: (RoutingMode) -> Unit, onExceptions: () -> Unit, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Background) {
        Column(Modifier.widthIn(max = 520.dp).fillMaxWidth().align(Alignment.CenterHorizontally).verticalScroll(rememberScrollState())
            .padding(start = 20.dp, end = 20.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.routing_title), style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(2.dp))
            RoutingMode.entries.forEach { value ->
                OptionRow(Modifier.selectable(mode == value, enabled = !running, role = Role.RadioButton, onClick = { onRouting(value) }),
                    selected = mode == value) {
                    Text(stringResource(if (value == RoutingMode.ALL) R.string.route_all else R.string.route_ru),
                        style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                    if (mode == value) Icon(Icons.Default.Check, null, tint = Cyan)
                }
            }
            Text(stringResource(if (mode == RoutingMode.ALL) R.string.route_all_hint else R.string.route_ru_hint),
                color = Muted, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 4.dp))
            SummaryRow(R.drawable.ic_route, stringResource(R.string.routing_exceptions), null, onExceptions)
            if (running) Text(stringResource(R.string.edit_disconnected), color = Cyan.copy(alpha = .7f), style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun SummaryRow(icon: Int, title: String, subtitle: String?, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = RoundedCornerShape(20.dp), color = Panel, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(start = 18.dp, end = 12.dp, top = 14.dp, bottom = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(icon), null, tint = Cyan, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (subtitle != null) Text(subtitle, color = Muted, style = MaterialTheme.typography.bodySmall,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Muted)
        }
    }
}

@Composable
private fun OptionRow(modifier: Modifier, selected: Boolean, content: @Composable RowScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(18.dp), color = Panel, modifier = Modifier.fillMaxWidth(),
        border = if (selected) BorderStroke(1.dp, Cyan.copy(alpha = .45f)) else null) {
        Row(modifier.heightIn(min = 56.dp).padding(start = 18.dp, end = 10.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically, content = content)
    }
}

@Composable
private fun RowScope.SourceButton(icon: Int, label: Int, enabled: Boolean, onClick: () -> Unit) {
    Surface(onClick = onClick, enabled = enabled, shape = RoundedCornerShape(18.dp), color = Panel,
        contentColor = if (enabled) Cyan else Muted.copy(alpha = .5f), modifier = Modifier.weight(1f)) {
        Column(Modifier.padding(vertical = 14.dp, horizontal = 6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(painterResource(icon), null, modifier = Modifier.size(22.dp))
            Spacer(Modifier.height(6.dp))
            Text(stringResource(label), style = MaterialTheme.typography.labelLarge, textAlign = TextAlign.Center, maxLines = 1)
        }
    }
}

@Composable
private fun ExceptionsDialog(
    overrides: RoutingOverrides, damaged: Boolean, reconnect: Boolean, saving: Boolean,
    onAdd: suspend (String, Boolean) -> Int?, onRemove: suspend (String, Boolean) -> Int?, onDismiss: () -> Unit,
) {
    val directInput = rememberSaveable { mutableStateOf("") }
    val proxyInput = rememberSaveable { mutableStateOf("") }
    val directError = rememberSaveable { mutableStateOf<Int?>(null) }
    val proxyError = rememberSaveable { mutableStateOf<Int?>(null) }
    val scope = rememberCoroutineScope()
    Dialog(onDismissRequest = { if (!saving) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding(), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(Modifier.widthIn(max = 520.dp).fillMaxWidth().padding(start = 24.dp, end = 12.dp, top = 12.dp, bottom = 12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.routing_exceptions), style = MaterialTheme.typography.headlineSmall,
                        modifier = Modifier.weight(1f))
                    IconButton(onClick = onDismiss, enabled = !saving) { Icon(Icons.Default.Close, stringResource(R.string.close)) }
                }
                LazyColumn(Modifier.widthIn(max = 520.dp).fillMaxWidth().weight(1f),
                    contentPadding = PaddingValues(start = 24.dp, end = 24.dp, bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(stringResource(R.string.routing_exceptions_hint), style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (damaged) Text(stringResource(R.string.routing_overrides_damaged),
                                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
                            if (reconnect) Text(stringResource(R.string.routing_reconnect_hint),
                                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    for (direct in listOf(true, false)) {
                        val input = if (direct) directInput else proxyInput
                        val error = if (direct) directError else proxyError
                        val names = if (direct) overrides.direct else overrides.proxy
                        item(key = "$direct:input") {
                            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Text(stringResource(if (direct) R.string.routing_exceptions_direct else R.string.routing_exceptions_proxy),
                                    style = MaterialTheme.typography.titleLarge)
                                OutlinedTextField(input.value, onValueChange = { input.value = it; error.value = null },
                                    label = { Text(stringResource(R.string.routing_site_address)) },
                                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri),
                                    singleLine = true, enabled = !saving, isError = error.value != null,
                                    supportingText = error.value?.let { resource -> { Text(stringResource(resource)) } },
                                    modifier = Modifier.fillMaxWidth())
                                Button(onClick = { scope.launch {
                                    error.value = onAdd(input.value, direct)
                                    if (error.value == null) input.value = ""
                                } }, enabled = !saving && input.value.isNotBlank(), modifier = Modifier.fillMaxWidth()) {
                                    Text(stringResource(R.string.routing_add))
                                }
                            }
                        }
                        if (names.isEmpty()) item(key = "$direct:empty") {
                            Text(stringResource(R.string.routing_empty), style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        items(names, key = { "$direct:$it" }) { domain ->
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Text(domain, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                                IconButton(onClick = { scope.launch { error.value = onRemove(domain, direct) } }, enabled = !saving) {
                                    Icon(Icons.Default.Delete, stringResource(R.string.routing_remove, domain))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PortalButton(phase: TunnelPhase, statusText: String, enabled: Boolean, onClick: () -> Unit) {
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
        val interaction = remember { MutableInteractionSource() }
        val pressed by interaction.collectIsPressedAsState()
        PortalEffect(phase, diameter, logoBounds, pressed, Backdrop, Modifier.matchParentSize())
        // The ring reads as the edge of the button, so a tap anywhere up to its outer edge counts.
        // It answers the press itself, so there is no ripple on top of it.
        Box(Modifier.size(diameter * 1.5f).clip(CircleShape)
            .clickable(interaction, indication = null, enabled = enabled && phase != TunnelPhase.STOPPING,
                role = Role.Button, onClick = onClick)
            .semantics { stateDescription = statusText },
            contentAlignment = Alignment.Center) {
            Column(Modifier.size(diameter), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center) {
                Spacer(Modifier.size(diameter * .38f).onGloballyPositioned { logoCoordinates = it; updateLogoBounds() })
                Spacer(Modifier.height(8.dp))
                Text(stringResource(if (running) R.string.disconnect else R.string.connect),
                    color = Cyan, style = MaterialTheme.typography.labelLarge, textAlign = TextAlign.Center,
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
        icon = { Icon(painterResource(R.drawable.ic_portal), null, Modifier.size(40.dp), tint = Cyan) },
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
