import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: VPNController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImport = false
    @State private var importText = ""
    @State private var showAbout = false
    @State private var showConsent = false
    @State private var showConnection = false
    @State private var showRouting = false
    @State private var exceptionCount = 0

    var body: some View {
        ZStack {
            LinearGradient(colors: [Brand.pageTop, Brand.background], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text(L("app_name")).font(.title.weight(.semibold)).tracking(-1).frame(maxWidth: .infinity, alignment: .leading)
                        Button { showAbout = true } label: { Image(systemName: "info.circle.fill").font(.title3).frame(width: 44, height: 44) }
                            .foregroundColor(Brand.muted).accessibilityLabel(L("about"))
                    }
                    Spacer().frame(height: 12)
                    PortalButton(phase: controller.phase, enabled: true) {
                        if controller.phase.running { controller.disconnect() }
                        else if controller.profile == nil { showConnection = true }
                        else if ProfileStore.preferences.bool(forKey: "vpn_consent") { controller.connect() }
                        else { showConsent = true }
                    }
                    // Always one line, so the rows below never move when the phase changes.
                    Spacer().frame(height: 18)
                    Text(L(controller.phase.rawValue)).font(.subheadline).foregroundColor(Brand.muted)
                        .lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: 330)
                        .contentTransition(.opacity).animation(.easeInOut(duration: 0.25), value: controller.phase)
                    Spacer().frame(height: 28)
                    if let error = controller.error {
                        HStack {
                            Text(error).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            Button { controller.error = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel(L("dismiss_error"))
                        }
                        .foregroundColor(Color(red: 1, green: 0.71, blue: 0.67)).padding(12)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                        .padding(.bottom, 16)
                    }
                    SummaryRow(icon: "server.rack", title: controller.profile?.name ?? L("add_profile"),
                               subtitle: L(controller.profile == nil ? "add_profile_hint" : "own_profile")) { showConnection = true }
                    Spacer().frame(height: 10)
                    SummaryRow(icon: "arrow.triangle.branch", title: L(controller.routing == .all ? "route_all" : "route_ru"),
                               subtitle: exceptionCount > 0 ? String(format: L("routing_exceptions_count"), exceptionCount) : nil) { showRouting = true }
                }
                .padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundColor(Brand.text)
        .onAppear { controller.activate(); refreshExceptionCount() }
        .onDisappear { controller.deactivate() }
        .onChange(of: scenePhase) { value in if value == .active { controller.activate() } else { controller.deactivate() } }
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
        .sheet(isPresented: $showConsent) {
            ConsentView {
                showConsent = false; ProfileStore.preferences.set(true, forKey: "vpn_consent"); controller.connect()
            }
        }
    }

    private func refreshExceptionCount() {
        exceptionCount = (try? RoutingOverrideStore.read()).map { $0.direct.count + $0.proxy.count } ?? 0
    }
}

private func sectionLabel(_ key: String) -> some View {
    Text(L(key)).font(.caption2.weight(.semibold)).tracking(1.3).foregroundColor(Brand.muted)
}

private struct SummaryRow: View {
    let icon: String
    let title: String
    let subtitle: String?
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
    private enum Step: Identifiable { case scan, review; var id: Self { self } }
    @ObservedObject var controller: VPNController
    @State private var step: Step?
    @State private var showFile = false
    @State private var showRemove = false
    @State private var importText = ""
    @State private var error: String?

    var body: some View {
        let running = controller.phase.running
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("connection_title")).font(.title2.weight(.semibold)).padding(.bottom, 4)
                if let profile = controller.profile {
                    sectionLabel("profile").padding(.top, 8)
                    OptionRow(selected: true) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).lineLimit(2)
                            Text(profile.server).font(.footnote).foregroundColor(Brand.muted).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
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
                if let error { Text(error).font(.footnote).foregroundColor(Color(red: 1, green: 0.71, blue: 0.67)) }
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 24).frame(maxWidth: 520).frame(maxWidth: .infinity)
            .modifier(FitSheet())
        }
        .foregroundColor(Brand.text)
        .background(Brand.background.ignoresSafeArea())
        .preferredColorScheme(.dark).tint(Brand.cyan)
        .sheet(item: $step) { value in
            switch value {
            case .scan: QRScanner { code in importText = code; step = .review }
            case .review: ImportProfileView(controller: controller, text: $importText)
            }
        }
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.json, .plainText]) { result in
            do { importText = try ImportProfileView.readFile(result.get()); error = nil; step = .review }
            catch { self.error = L("read_failed") }
        }
        .alert(L("remove_profile"), isPresented: $showRemove) {
            Button(L("remove"), role: .destructive) { controller.removeProfile() }
            Button(L("cancel"), role: .cancel) { }
        } message: { Text(L("remove_confirm")) }
    }

    @ViewBuilder private var sourceButtons: some View {
        PasteButton(payloadType: String.self) { values in
            guard let value = values.first else { return }
            Task { @MainActor in importText = String(value.prefix(ConnectionProfile.maximumLength + 1)); step = .review }
        }
        .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).tint(Brand.ready)
        sourceButton("qrcode.viewfinder", "source_qr") { step = .scan }
        sourceButton("doc", "source_file") { showFile = true }
    }

    private func sourceButton(_ icon: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(L(key), systemImage: icon).lineLimit(1) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Brand.ready).foregroundColor(.white)
    }
}

private struct FitSheet: ViewModifier {
    @State private var height: CGFloat = 320
    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height) })
            .onPreferenceChange(SheetHeightKey.self) { height = $0 + 12 }
            .presentationDetents([.height(height), .large]).presentationDragIndicator(.visible)
    }
}

private struct SheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct RoutingSheet: View {
    @ObservedObject var controller: VPNController
    @State private var showOverrides = false

    var body: some View {
        let running = controller.phase.running
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("routing_title")).font(.title2.weight(.semibold)).padding(.bottom, 6)
                ForEach(RoutingMode.allCases, id: \.rawValue) { mode in
                    Button { controller.setRouting(mode) } label: {
                        OptionRow(selected: controller.routing == mode) {
                            Text(L(mode == .all ? "route_all" : "route_ru")).frame(maxWidth: .infinity, alignment: .leading)
                            if controller.routing == mode { Image(systemName: "checkmark").foregroundColor(Brand.cyan).padding(.trailing, 6) }
                        }.contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain).disabled(running)
                    .accessibilityAddTraits(controller.routing == mode ? .isSelected : [])
                }
                Text(L(controller.routing == .all ? "route_all_hint" : "route_ru_hint")).font(.footnote).foregroundColor(Brand.muted)
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
        .sheet(isPresented: $showOverrides) { RoutingOverridesView(controller: controller) }
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
                                .frame(minHeight: 44).buttonStyle(.bordered).buttonBorderShape(.capsule)
                            if let clearError { Text(L(clearError)).font(.subheadline).foregroundColor(Brand.muted).fixedSize(horizontal: false, vertical: true) }
                        }
                    }.listRowBackground(Brand.panel)
                }
                overrideSection(.direct, input: $directInput, error: $directError)
                overrideSection(.proxy, input: $proxyInput, error: $proxyError)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background(Brand.background).foregroundColor(Brand.cyan)
            .navigationTitle(L("overrides_title")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("close")) { dismiss() } } }
        }
        .preferredColorScheme(.dark).tint(Brand.cyan)
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
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .submitLabel(.done).padding(.vertical, 8)
                    .onSubmit { add(to: list, input: input, error: error) }
                    .onChange(of: input.wrappedValue) { _ in error.wrappedValue = nil }
                if let key = error.wrappedValue {
                    Text(L(key)).font(.subheadline).foregroundColor(Brand.muted).fixedSize(horizontal: false, vertical: true)
                }
                Button(L("overrides_add")) { add(to: list, input: input, error: error) }
                    .frame(minHeight: 44).buttonStyle(.bordered).buttonBorderShape(.capsule)
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
                .background(Brand.background).navigationTitle(L("consent_title")).navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) { Button(L("agree_connect"), action: agree).buttonStyle(.borderedProminent).foregroundColor(Brand.ink).padding(20) }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Brand.cyan)
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
                        Link(L("source_code"), destination: URL(string: "https://github.com/chromvoid/wayveil/releases/tag/ios-v0.1.0-build.8")!)
                    }
                }.padding(24)
            }
            .background(Brand.background).navigationTitle(L(licenses ? "licenses" : "about")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("close")) { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Brand.cyan)
    }
}
