import SwiftUI
import CoreImage.CIFilterBuiltins
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @ObservedObject var controller: VPNController
    #if os(iOS)
    @StateObject private var updateChecker = AppUpdateChecker()
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @State private var showImport = false
    @State private var importText = ""
    @State private var showAbout = false
    @State private var showConsent = false
    @State private var showConnection = false
    @State private var showRouting = false
    @State private var showStats = false
    @State private var exceptionCount = 0

    #if os(iOS)
    private static let addProfileHint = "add_profile_hint"
    #else
    // A Mac has no camera QR scanning, so the hint names only what it offers.
    private static let addProfileHint = "add_profile_hint_mac"
    #endif

    var body: some View {
        ZStack {
            LinearGradient(colors: [Brand.pageTop, Brand.background], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text(L("app_name")).font(.title.weight(.semibold)).tracking(-1).frame(maxWidth: .infinity, alignment: .leading)
                        Button { showAbout = true } label: { Image(systemName: "info.circle.fill").font(.title3).frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).foregroundColor(Brand.muted).accessibilityLabel(L("about"))
                    }
                    Spacer().frame(height: 12)
                    PortalButton(phase: controller.phase, traffic: liveTraffic, enabled: true) {
                        if controller.phase.running { controller.disconnect() }
                        else { connect() }
                    }
                    // Always one line, so the rows below never move when the phase changes.
                    Spacer().frame(height: 18)
                    Text(L(controller.presentation.waitingForServer ? "waiting_server" : controller.phase.rawValue)).font(.subheadline).foregroundColor(Brand.muted)
                        .lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: 330)
                        .contentTransition(.opacity).animation(.easeInOut(duration: 0.25), value: controller.phase)
                    Spacer().frame(height: 28)
                    if let error = controller.presentation.visibleError {
                        HStack {
                            Text(error).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            Button { controller.clearError() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel(L("dismiss_error"))
                        }
                        .foregroundColor(Color(red: 1, green: 0.71, blue: 0.67)).padding(12)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                        .padding(.bottom, 16)
                    }
                    #if os(iOS)
                    if updateChecker.available {
                        SummaryRow(icon: "arrow.down.circle.fill", title: L("update_available"),
                                   subtitle: L("update_available_hint"), border: Brand.cyan.opacity(0.45)) { updateChecker.openAppStore() }
                        Spacer().frame(height: 10)
                    }
                    #endif
                    SummaryRow(icon: "server.rack",
                               title: controller.access != nil ? controller.presentation.title : controller.profile?.name ?? L("add_profile"),
                               subtitle: controller.access != nil ? controller.presentation.subtitle : L(controller.profile == nil ? Self.addProfileHint : "own_profile")) { showConnection = true }
                    Spacer().frame(height: 10)
                    SummaryRow(icon: "arrow.triangle.branch", title: L("route_ru"),
                               subtitle: exceptionCount > 0 ? String(format: L("routing_exceptions_count"), exceptionCount) : nil) { showRouting = true }
                    if controller.canConnect || controller.phase.running || statsSubtitle != nil {
                        Spacer().frame(height: 10)
                        SummaryRow(icon: "chart.bar.fill", title: L("stats_title"), subtitle: statsSubtitle) { showStats = true }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundColor(Brand.text)
        .onAppear {
            controller.activate()
            refreshExceptionCount()
            #if os(iOS)
            connectIfRequestedByControl()
            #endif
        }
        #if os(iOS)
        .task { await updateChecker.check() }
        #endif
        .onDisappear { controller.deactivate() }
        .onChange(of: scenePhase) { value in
            if value == .active {
                controller.activate()
                #if os(iOS)
                connectIfRequestedByControl()
                Task { await updateChecker.check() }
                #endif
            } else { controller.deactivate() }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: controlConnectRequestedNotification)) { _ in
            connectIfRequestedByControl()
        }
        #endif
        .onOpenURL { url in
            guard !controller.phase.running else { controller.error = L("disconnect_first"); return }
            if url.isFileURL {
                do { importText = try ImportProfileView.readFile(url); showImport = true }
                catch { controller.error = L("read_failed") }
            } else { importText = url.absoluteString; showImport = true }
        }
        .sheet(isPresented: $showImport) { ImportProfileView(controller: controller, text: $importText) }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showConnection) { ConnectionSheet(controller: controller) }
        .sheet(isPresented: $showRouting, onDismiss: refreshExceptionCount) { RoutingSheet(controller: controller) }
        .sheet(isPresented: $showStats) { StatsSheet(controller: controller) }
        .sheet(isPresented: $showConsent) {
            ConsentView {
                showConsent = false; ProfileStore.preferences.set(true, forKey: "vpn_consent"); controller.connect()
            }
        }
    }

    #if os(iOS)
    private func connectIfRequestedByControl() {
        guard ProfileStore.preferences.bool(forKey: "control_connect_requested") else { return }
        ProfileStore.preferences.removeObject(forKey: "control_connect_requested")
        connect()
    }
    #endif

    private func connect() {
        guard !controller.phase.running else { return }
        if !controller.canConnect { showConnection = true }
        else if ProfileStore.preferences.bool(forKey: "vpn_consent") { controller.connect() }
        else { showConsent = true }
    }

    private func refreshExceptionCount() {
        exceptionCount = (try? RoutingOverrideStore.read()).map { $0.direct.count + $0.proxy.count } ?? 0
    }

    /// Download and upload together, while connected.
    private var liveTraffic: Double? {
        guard controller.phase == .connected, let download = controller.liveDownloadBps else { return nil }
        return download + (controller.liveUploadBps ?? 0)
    }

    private var statsSubtitle: String? {
        if controller.phase == .connected {
            let latency = controller.currentMetrics?.currentLatencyMs.map { TunnelMetricsFormat.latency($0, locale: locale) }
            var speed: String?
            if let download = controller.liveDownloadBps, let upload = controller.liveUploadBps {
                speed = "↓ \(TunnelMetricsFormat.speed(download, locale: locale))  ↑ \(TunnelMetricsFormat.speed(upload, locale: locale))"
            }
            let parts = [latency, speed].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        if controller.phase.running { return nil }
        guard let total = controller.metrics?.total, total.downloadBytes + total.uploadBytes > 0 else { return nil }
        return String(format: L("stats_total_summary"), TunnelMetricsFormat.bytes(total.downloadBytes + total.uploadBytes, locale: locale))
    }
}

private func sectionLabel(_ key: String) -> some View {
    Text(L(key)).font(.caption2.weight(.semibold)).tracking(1.3).foregroundColor(Brand.muted)
}

private struct SummaryRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    var border: Color? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundColor(Brand.cyan).frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.footnote).foregroundColor(Brand.muted).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(Brand.muted).accessibilityHidden(true)
            }
            .padding(.leading, 18).padding(.trailing, 16).padding(.vertical, 14)
            .background(Brand.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(border ?? .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }
}

private struct OptionRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.leading, 18).padding(.trailing, 12).padding(.vertical, 8).frame(minHeight: 56)
            .background(Brand.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.cyan.opacity(selected ? 0.45 : 0), lineWidth: 1))
    }
}

private struct ConnectionSheet: View {
    private enum Step: Identifiable {
        #if os(iOS)
        case scan
        #endif
        case review
        var id: Self { self }
    }
    private struct ProfileExport: Identifiable {
        let id = UUID()
        let link: String
        let qrCode: CGImage?
    }
    private static let qrContext = CIContext()
    @ObservedObject var controller: VPNController
    @Environment(\.locale) private var locale
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var step: Step?
    @State private var showFile = false
    @State private var showRemove = false
    @State private var showRemoveAccess = false
    @State private var profileExport: ProfileExport?
    @State private var importText = ""
    @State private var error: String?

    var body: some View {
        let running = controller.phase.running
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("connection_title")).font(.title2.weight(.semibold)).padding(.bottom, 4)
                if controller.access != nil {
                    catalogSection
                } else {
                    if let profile = controller.profile {
                        sectionLabel("profile").padding(.top, 8)
                        OptionRow(selected: true) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).lineLimit(2)
                                Text(profile.server).font(.footnote).foregroundColor(Brand.muted).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                let link = profile.exportLink()
                                profileExport = ProfileExport(link: link, qrCode: Self.makeQRCode(link))
                            } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                                .foregroundColor(Brand.muted).accessibilityLabel(L("export_profile"))
                            Button { showRemove = true } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                                .foregroundColor(Brand.muted).disabled(running).accessibilityLabel(L("remove_profile"))
                        }
                    }
                    Text(L(controller.profile == nil ? "add_profile" : "replace_profile").uppercased())
                        .font(.caption2.weight(.semibold)).tracking(1.3).foregroundColor(Brand.muted).padding(.top, 8)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { sourceButtons }
                        VStack(alignment: .leading, spacing: 8) { sourceButtons }
                    }.disabled(running)
                    if running { Text(L("edit_disconnected")).font(.footnote).foregroundColor(Brand.cyan.opacity(0.7)) }
                }
                if let error { Text(error).font(.footnote).foregroundColor(Color(red: 1, green: 0.71, blue: 0.67)) }
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 24).frame(maxWidth: 520).frame(maxWidth: .infinity)
            .modifier(FitSheet())
        }
        .foregroundColor(Brand.text)
        .background(Brand.background.ignoresSafeArea())
        .preferredColorScheme(.dark).tint(Brand.cyan)
        #if os(macOS)
        .safeAreaInset(edge: .bottom) {
            Button(L("close")) { dismiss() }.keyboardShortcut(.cancelAction).padding(20)
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 480, idealHeight: 600)
        #endif
        .sheet(item: $step) { value in
            switch value {
            #if os(iOS)
            case .scan: QRScanner { code in importText = code; step = .review }
            #endif
            case .review: ImportProfileView(controller: controller, text: $importText)
            }
        }
        .sheet(item: $profileExport) { value in
            ExportProfileSheet(link: value.link, qrCode: value.qrCode)
        }
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.json, .plainText]) { result in
            do { importText = try ImportProfileView.readFile(result.get()); error = nil; step = .review }
            catch { self.error = L("read_failed") }
        }
        .alert(L("remove_profile"), isPresented: $showRemove) {
            Button(L("remove"), role: .destructive) { controller.removeProfile() }
            Button(L("cancel"), role: .cancel) { }
        } message: { Text(L("remove_confirm")) }
        .alert(L("remove_access"), isPresented: $showRemoveAccess) {
            Button(L("remove"), role: .destructive) {
                Task { @MainActor in
                    do { try await controller.removeAccess(); error = nil }
                    catch { self.error = accessError(error) }
                }
            }
            Button(L("cancel"), role: .cancel) { }
        } message: { Text(L("remove_access_confirm")) }
    }

    private var catalogSection: some View {
        Group {
            Text((controller.catalog.map { $0.label.isEmpty ? L("node_catalog") : $0.label } ?? L("node_catalog")).uppercased())
                .font(.caption2.weight(.semibold)).tracking(1.3).foregroundColor(Brand.muted).padding(.top, 8)
            if let expiresAt = controller.catalog?.expiresAt, expiresAt != 0 {
                Text(String(format: L("access_valid_until"), accessDate(expiresAt)))
                    .font(.footnote).foregroundColor(Brand.muted)
            }
            ForEach(controller.catalog?.nodes ?? [], id: \.id) { node in
                Button {
                    Task { @MainActor in
                        do { try await controller.selectNode(node.id); error = nil }
                        catch { self.error = accessError(error) }
                    }
                } label: {
                    OptionRow(selected: controller.access?.node == node.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(node.name).lineLimit(2)
                            if !node.ready {
                                Text(L("access_activating")).font(.footnote).foregroundColor(Brand.muted)
                            } else if !node.location.isEmpty {
                                Text(node.location).font(.footnote).foregroundColor(Brand.muted)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!node.ready || controller.phase.running || controller.accessLoading)
            }
            Button(L(controller.accessLoading ? "catalog_refreshing" : "refresh_catalog")) {
                Task { await controller.refreshCatalog() }
            }.buttonStyle(.bordered).disabled(controller.accessLoading).padding(.top, 8)
            Button(L("remove_access"), role: .destructive) { showRemoveAccess = true }
                .buttonStyle(.bordered).disabled(controller.phase.running || controller.accessLoading)
        }
    }

    private func accessDate(_ timestamp: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private func accessError(_ error: Error) -> String {
        (error as? AccessFailure).map { L(AccessPresentation.errorKey($0.code)) } ?? L("save_failed")
    }

    @ViewBuilder private var sourceButtons: some View {
        #if os(iOS)
        PasteButton(payloadType: String.self) { values in
            guard let value = values.first else { return }
            Task { @MainActor in importText = String(value.prefix(ConnectionProfile.maximumLength + 1)); step = .review }
        }
        .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).tint(Brand.ready)
        sourceButton("qrcode.viewfinder", "source_qr") { step = .scan }
        #else
        // A Mac reads the pasteboard without asking, and the system paste button stays disabled for a copied link.
        sourceButton("doc.on.clipboard", "source_paste") {
            guard let value = NSPasteboard.general.string(forType: .string) else { return }
            importText = String(value.prefix(ConnectionProfile.maximumLength + 1)); step = .review
        }
        #endif
        sourceButton("doc", "source_file") { showFile = true }
    }

    private func sourceButton(_ icon: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(L(key), systemImage: icon).lineLimit(1) }
            .buttonStyle(.borderedProminent)
            #if os(iOS)
            .buttonBorderShape(.capsule)
            #endif
            .tint(Brand.ready).foregroundColor(.white)
    }

    private static func makeQRCode(_ link: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        for level in ["M", "L"] {
            filter.correctionLevel = level
            if let image = filter.outputImage {
                let bounds = image.extent.insetBy(dx: -4, dy: -4)
                let background = CIImage(color: .white).cropped(to: bounds)
                return qrContext.createCGImage(image.composited(over: background), from: bounds)
            }
        }
        return nil
    }
}

private struct ExportProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copiedAt: Date?
    let link: String
    let qrCode: CGImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(L("export_warning")).font(.subheadline).foregroundColor(Brand.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let qrCode {
                        Image(decorative: qrCode, scale: 1).resizable().interpolation(.none).scaledToFit()
                            .frame(maxWidth: 320).accessibilityHidden(true)
                    } else {
                        Text(L("export_qr_too_large")).font(.subheadline).foregroundColor(Brand.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        #if os(iOS)
                        UIPasteboard.general.setItems([["public.utf8-plain-text": link]],
                            options: [.expirationDate: Date().addingTimeInterval(5 * 60)])
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        #endif
                        copiedAt = Date()
                    } label: {
                        Label(L(copiedAt != nil ? "copied" : "copy_link"), systemImage: copiedAt != nil ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).foregroundColor(Brand.ink)
                    .task(id: copiedAt) {
                        guard copiedAt != nil else { return }
                        do { try await Task.sleep(nanoseconds: 2_000_000_000); copiedAt = nil }
                        catch { }
                    }
                    ShareLink(item: link) {
                        Label(L("share"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered)
                }.padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
            .background(Brand.background).foregroundColor(Brand.text)
            .navigationTitle(L("export_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("close")) { dismiss() } } }
        }
        .preferredColorScheme(.dark).tint(Brand.cyan)
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 520, idealHeight: 640)
        #endif
    }
}

private struct FitSheet: ViewModifier {
    @State private var height: CGFloat = 320
    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background(GeometryReader { proxy in Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height) })
            .onPreferenceChange(SheetHeightKey.self) { height = $0 + 12 }
            .presentationDetents([.height(height), .large]).presentationDragIndicator(.visible)
            #endif
    }
}

private struct SheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct RoutingSheet: View {
    @ObservedObject var controller: VPNController
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var showOverrides = false

    var body: some View {
        let running = controller.phase.running
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("routing_title")).font(.title2.weight(.semibold)).padding(.bottom, 6)
                Text(L("route_ru_hint")).font(.footnote).foregroundColor(Brand.muted)
                    .padding(.horizontal, 4)
                SummaryRow(icon: "list.bullet", title: L("overrides_title"), subtitle: nil) { showOverrides = true }
                if running { Text(L("edit_disconnected")).font(.footnote).foregroundColor(Brand.cyan.opacity(0.7)) }
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 24).frame(maxWidth: 520).frame(maxWidth: .infinity)
            .modifier(FitSheet())
        }
        .foregroundColor(Brand.text)
        .background(Brand.background.ignoresSafeArea())
        .preferredColorScheme(.dark).tint(Brand.cyan)
        #if os(macOS)
        .safeAreaInset(edge: .bottom) {
            Button(L("close")) { dismiss() }.keyboardShortcut(.cancelAction).padding(20)
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 480, idealHeight: 600)
        #endif
        .sheet(isPresented: $showOverrides) { RoutingOverridesView(controller: controller) }
    }
}

private struct StatsSheet: View {
    @ObservedObject var controller: VPNController
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @Environment(\.locale) private var locale

    private var connected: Bool { controller.phase == .connected }
    private var sessionMetrics: TunnelMetricsSnapshot? { connected ? controller.currentMetrics : controller.metrics }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("stats_title")).font(.title2.weight(.semibold)).padding(.bottom, 6)
                statsSection("stats_server") {
                    statsRow("stats_server", value: controller.connectionProfile?.name ?? "—")
                    statsRow("stats_address", value: serverAddress)
                    statsRow("stats_protocol", value: "Hysteria2 · UDP")
                }
                statsSection("stats_latency") {
                    statsRow("stats_now", value: latency(controller.currentMetrics?.currentLatencyMs))
                    statsRow("stats_median", value: latency(controller.currentMetrics?.medianLatencyMs))
                }
                statsSection("stats_speed") {
                    statsRow("stats_now", value: liveSpeed)
                    statsRow("stats_median_download", value: downloadSpeed(sessionMetrics?.downloadMedianBps))
                    statsRow("stats_peak", value: downloadSpeed(sessionMetrics?.downloadPeakBps))
                }
                Text(L("stats_median_hint")).font(.footnote).foregroundColor(Brand.muted).padding(.horizontal, 4)
                statsSection("stats_traffic") {
                    statsRow("stats_session", value: traffic(sessionMetrics?.session ?? TunnelTraffic()))
                    statsRow("stats_month", value: traffic(controller.metrics?.monthTraffic() ?? TunnelTraffic()))
                    statsRow("stats_total", value: traffic(controller.metrics?.total ?? TunnelTraffic()), detail: trackingSince)
                }
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 24).frame(maxWidth: 520).frame(maxWidth: .infinity)
            .modifier(FitSheet())
        }
        .foregroundColor(Brand.text)
        .background(Brand.background.ignoresSafeArea())
        .preferredColorScheme(.dark).tint(Brand.cyan)
        #if os(macOS)
        .safeAreaInset(edge: .bottom) {
            Button(L("close")) { dismiss() }.keyboardShortcut(.cancelAction).padding(20)
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 480, idealHeight: 600)
        #endif
        .onAppear { controller.setStatsVisible(true) }
        .onDisappear { controller.setStatsVisible(false) }
    }

    private func statsSection<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(key).textCase(.uppercase).padding(.horizontal, 4)
            VStack(spacing: 16, content: content).padding(18)
                .background(Brand.panel, in: RoundedRectangle(cornerRadius: 20))
        }.padding(.top, 8)
    }

    private func statsRow(_ key: String, value: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L(key)).foregroundColor(Brand.muted)
            VStack(alignment: .trailing, spacing: 3) {
                Text(value).monospacedDigit()
                if let detail { Text(detail).font(.caption).foregroundColor(Brand.muted) }
            }.frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing)
        }.font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }

    private var serverAddress: String {
        guard let profile = controller.connectionProfile else { return "—" }
        let server = profile.server.contains(":") ? "[\(profile.server)]" : profile.server
        return "\(server):\(profile.port)"
    }

    private func latency(_ value: Double?) -> String {
        guard connected, let value else { return "—" }
        return TunnelMetricsFormat.latency(value, locale: locale)
    }

    private var liveSpeed: String {
        guard connected, let download = controller.liveDownloadBps, let upload = controller.liveUploadBps else { return "—" }
        return "↓ \(TunnelMetricsFormat.speed(download, locale: locale))  ↑ \(TunnelMetricsFormat.speed(upload, locale: locale))"
    }

    private func downloadSpeed(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return TunnelMetricsFormat.speed(value, locale: locale)
    }

    private func traffic(_ value: TunnelTraffic) -> String {
        "↓ \(TunnelMetricsFormat.bytes(value.downloadBytes, locale: locale))  ↑ \(TunnelMetricsFormat.bytes(value.uploadBytes, locale: locale))"
    }

    private var trackingSince: String? {
        guard let date = controller.metrics?.trackingStartedAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        return String(format: L("stats_since"), formatter.string(from: date))
    }
}

private struct RoutingOverridesView: View {
    @ObservedObject var controller: VPNController
    @Environment(\.dismiss) private var dismiss
    @State private var overrides = RoutingOverrides.empty
    @State private var directInput = ""
    @State private var proxyInput = ""
    @State private var directError: String?
    @State private var proxyError: String?
    @State private var damaged = false
    @State private var clearError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L("overrides_hint")).foregroundColor(Brand.muted).fixedSize(horizontal: false, vertical: true)
                    if controller.phase.running {
                        Text(L("overrides_reconnect")).foregroundColor(Brand.cyan).fixedSize(horizontal: false, vertical: true)
                    }
                }.listRowBackground(Brand.panel)
                if damaged {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("overrides_damaged")).fixedSize(horizontal: false, vertical: true)
                            Button(L("overrides_clear")) { clear() }
                                .frame(minHeight: 44).buttonStyle(.bordered)
                                #if os(iOS)
                                .buttonBorderShape(.capsule)
                                #endif
                            if let clearError { Text(L(clearError)).font(.subheadline).foregroundColor(Brand.muted).fixedSize(horizontal: false, vertical: true) }
                        }
                    }.listRowBackground(Brand.panel)
                }
                overrideSection(.direct, input: $directInput, error: $directError)
                overrideSection(.proxy, input: $proxyInput, error: $proxyError)
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
            .background(Brand.background).foregroundColor(Brand.cyan)
            .navigationTitle(L("overrides_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("close")) { dismiss() } } }
        }
        .preferredColorScheme(.dark).tint(Brand.cyan)
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 520, idealHeight: 640)
        #endif
        .onAppear {
            do { overrides = try RoutingOverrideStore.read() }
            catch { damaged = true }
        }
    }

    private func overrideSection(_ list: RoutingOverrides.List, input: Binding<String>, error: Binding<String?>) -> some View {
        let names = list == .direct ? overrides.direct : overrides.proxy
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("overrides_address")).font(.caption).foregroundColor(Brand.muted)
                TextField(L("overrides_address"), text: input, axis: .vertical)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    .submitLabel(.done).padding(.vertical, 8)
                    .onSubmit { add(to: list, input: input, error: error) }
                    .onChange(of: input.wrappedValue) { _ in error.wrappedValue = nil }
                if let key = error.wrappedValue {
                    Text(L(key)).font(.subheadline).foregroundColor(Brand.muted).fixedSize(horizontal: false, vertical: true)
                }
                Button(L("overrides_add")) { add(to: list, input: input, error: error) }
                    .frame(minHeight: 44).buttonStyle(.bordered)
                    #if os(iOS)
                    .buttonBorderShape(.capsule)
                    #endif
            }
            if names.isEmpty {
                Text(L("overrides_empty")).font(.subheadline).foregroundColor(Brand.muted)
            }
            ForEach(names, id: \.self) { name in
                HStack(alignment: .top, spacing: 8) {
                    Text(name).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { remove(name, from: list, error: error) } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless).accessibilityLabel(L("remove"))
                }
                .swipeActions {
                    Button(L("remove")) { remove(name, from: list, error: error) }.tint(Brand.ready)
                }
            }
        } header: {
            Text(L(list == .direct ? "overrides_direct" : "overrides_proxy"))
                .font(.headline).foregroundColor(Brand.cyan).textCase(nil).fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(Brand.panel)
    }

    private func add(to list: RoutingOverrides.List, input: Binding<String>, error: Binding<String?>) {
        do {
            overrides = try RoutingOverrideStore.add(input.wrappedValue, to: list)
            input.wrappedValue = ""; error.wrappedValue = nil
        } catch let failure { show(failure, error: error) }
    }

    private func remove(_ name: String, from list: RoutingOverrides.List, error: Binding<String?>) {
        do {
            overrides = try RoutingOverrideStore.remove(name, from: list)
            error.wrappedValue = nil
        } catch let failure { show(failure, error: error) }
    }

    private func show(_ failure: Error, error: Binding<String?>) {
        let key = RoutingOverrideStore.errorKey(failure)
        if key == "overrides_damaged" {
            damaged = true; overrides = .empty; error.wrappedValue = nil
        } else { error.wrappedValue = key }
    }

    private func clear() {
        do {
            try RoutingOverrideStore.remove()
            overrides = .empty; damaged = false; clearError = nil; directError = nil; proxyError = nil
        } catch { clearError = RoutingOverrideStore.errorKey(error) }
    }
}

private struct ConsentView: View {
    let agree: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L("consent_body")).frame(maxWidth: .infinity, alignment: .leading)
                    Link(L("privacy_policy"), destination: URL(string: "https://link.chromvoid.com/privacy")!)
                        .frame(minHeight: 44)
                }.padding(24)
            }
            .background(Brand.background).navigationTitle(L("consent_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) { Button(L("agree_connect"), action: agree).buttonStyle(.borderedProminent).foregroundColor(Brand.ink).padding(20) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Brand.cyan)
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 520, idealHeight: 640)
        #endif
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var licenses = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image("Portal").resizable().renderingMode(.template).scaledToFit().frame(width: 72, height: 72).foregroundColor(Brand.cyan).accessibilityHidden(true)
                    if licenses {
                        Text((try? String(contentsOf: Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")!, encoding: .utf8)) ?? "")
                            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(String(format: L("about_body"), Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0", AppIdentity.coreVersion))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(L("licenses")) { licenses = true }
                        Link(L("privacy_policy"), destination: URL(string: "https://link.chromvoid.com/privacy")!)
                            .frame(minHeight: 44)
                        #if os(iOS)
                        Link(L("source_code"), destination: URL(string: "https://github.com/chromvoid/wayveil/releases/tag/ios-v0.1.1-build.9")!)
                        #else
                        Link(L("source_code"), destination: URL(string: "https://github.com/chromvoid/wayveil/releases/tag/ios-v0.1.0-build.8")!)
                        #endif
                    }
                }.padding(24)
            }
            .background(Brand.background).navigationTitle(L(licenses ? "licenses" : "about"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("close")) { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Brand.cyan)
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 520, idealHeight: 640)
        #endif
    }
}
