import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: VPNController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImport = false
    @State private var importText = ""
    @State private var showAbout = false
    @State private var showConsent = false
    @State private var showRemove = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 20 / 255, green: 46 / 255, blue: 54 / 255), Brand.background], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text(L("app_name")).font(.title.weight(.semibold)).tracking(-1).frame(maxWidth: .infinity, alignment: .leading)
                        Button { showAbout = true } label: { Image(systemName: "info.circle.fill").font(.title3).frame(width: 44, height: 44) }
                            .foregroundColor(Brand.muted).accessibilityLabel(L("about"))
                    }
                    Spacer().frame(height: 26)
                    Text(L("tagline")).font(.caption2.weight(.bold)).tracking(2).foregroundColor(Brand.mint).multilineTextAlignment(.center)
                    Spacer().frame(height: 10)
                    Text(L("subtitle")).font(.callout).foregroundColor(Brand.muted).multilineTextAlignment(.center)
                    Spacer().frame(height: 27)
                    HStack(spacing: 9) {
                        Circle().fill(controller.phase == .connected ? Brand.mint : Brand.muted).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(L(controller.phase.rawValue)).font(.footnote)
                    }
                    .foregroundColor(controller.phase == .connected ? Brand.mint : Brand.muted)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(controller.phase == .connected ? Brand.mint.opacity(0.12) : Brand.panel, in: Capsule())
                    .accessibilityElement(children: .combine)
                    Spacer().frame(height: 26)
                    PortalButton(phase: controller.phase, enabled: controller.profile != nil || controller.phase.running) {
                        if controller.phase.running { controller.disconnect() }
                        else if ProfileStore.preferences.bool(forKey: "vpn_consent") { controller.connect() }
                        else { showConsent = true }
                    }
                    Spacer().frame(height: 18)
                    Text(L(hint)).font(.subheadline).foregroundColor(Brand.muted).multilineTextAlignment(.center).frame(maxWidth: 330)
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
                    VStack(alignment: .leading, spacing: 14) {
                        sectionLabel("profile")
                        if let profile = controller.profile {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(profile.name).font(.headline).lineLimit(2)
                                    Text(profile.server).font(.caption).foregroundColor(Brand.muted).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button { showRemove = true } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                                    .foregroundColor(Brand.muted).disabled(controller.phase.running).accessibilityLabel(L("remove_profile"))
                            }
                        } else { Text(L("empty_title")).font(.headline) }
                        Button { importText = ""; showImport = true } label: {
                            Label(L(controller.profile == nil ? "add_profile" : "replace_profile"), systemImage: "plus")
                                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 9)
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(controller.phase.running)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Brand.panel, in: RoundedRectangle(cornerRadius: 24))
                    Spacer().frame(height: 16)
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("routing")
                        ForEach(RoutingMode.allCases, id: \.rawValue) { mode in
                            Button { controller.setRouting(mode) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: controller.routing == mode ? "largecircle.fill.circle" : "circle").font(.title3)
                                    Text(L(mode == .all ? "route_all" : "route_ru")).font(.subheadline).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }.frame(minHeight: 44)
                            }
                            .buttonStyle(.plain).disabled(controller.phase.running)
                            .foregroundColor(controller.routing == mode ? Brand.mint : Brand.muted)
                            .accessibilityAddTraits(controller.routing == mode ? .isSelected : [])
                        }
                        Text(L(controller.routing == .all ? "route_all_hint" : "route_ru_hint")).font(.caption).foregroundColor(Brand.muted)
                        if controller.phase.running { Text(L("edit_disconnected")).font(.caption).foregroundColor(Brand.mint.opacity(0.7)) }
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Brand.panel, in: RoundedRectangle(cornerRadius: 24))
                }
                .padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundColor(Color(red: 237 / 255, green: 244 / 255, blue: 243 / 255))
        .onAppear { controller.activate() }
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
        .sheet(isPresented: $showConsent) {
            ConsentView {
                showConsent = false; ProfileStore.preferences.set(true, forKey: "vpn_consent"); controller.connect()
            }
        }
        .alert(L("remove_profile"), isPresented: $showRemove) {
            Button(L("remove"), role: .destructive) { controller.removeProfile() }
            Button(L("cancel"), role: .cancel) { }
        } message: { Text(L("remove_confirm")) }
    }

    private var hint: String {
        switch controller.phase {
        case .connected: return "connected_hint"
        case .connecting: return "connecting_hint"
        case .reconnecting: return "reconnecting_hint"
        default: return controller.profile == nil ? "empty_hint" : "ready_hint"
        }
    }
    private func sectionLabel(_ key: String) -> some View {
        Text(L(key)).font(.caption2.weight(.semibold)).tracking(1.3).foregroundColor(Brand.muted)
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
        }.preferredColorScheme(.dark).tint(Brand.mint)
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var licenses = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image("Portal").resizable().renderingMode(.template).scaledToFit().frame(width: 72, height: 72).foregroundColor(Brand.mint).accessibilityHidden(true)
                    if licenses {
                        Text((try? String(contentsOf: Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")!, encoding: .utf8)) ?? "")
                            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(String(format: L("about_body"), Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0", AppIdentity.coreVersion))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(L("licenses")) { licenses = true }
                        Link(L("privacy_policy"), destination: URL(string: "https://link.chromvoid.com/privacy")!)
                            .frame(minHeight: 44)
                        Link(L("source_code"), destination: URL(string: "https://github.com/chromvoid/wayveil/releases/tag/ios-v0.1.0-build.4")!)
                    }
                }.padding(24)
            }
            .background(Brand.background).navigationTitle(L(licenses ? "licenses" : "about")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("close")) { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Brand.mint)
    }
}
