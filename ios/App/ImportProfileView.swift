import SwiftUI
import UniformTypeIdentifiers

struct ImportProfileView: View {
    @ObservedObject var controller: VPNController
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @State private var showFile = false
    #if os(iOS)
    @State private var showScanner = false
    #endif
    @State private var error: String?
    @State private var saving = false

    private var activating: Bool { Invitation.isLink(text) }

    #if os(iOS)
    private static let hint = "import_hint"
    #else
    private static let hint = "import_hint_mac"
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L(Self.hint)).foregroundColor(Brand.muted).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("profile_input")).font(.caption).foregroundColor(Brand.muted)
                        SecureField(L("profile_input"), text: limitedText)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .disabled(saving)
                            .padding(.vertical, 20)
                    }
                    .padding(16).background(Brand.panel, in: RoundedRectangle(cornerRadius: 16))
                    if activating {
                        Text(L("activation_disclosure")).font(.footnote).foregroundColor(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(L("privacy_policy"), destination: URL(string: "https://link.chromvoid.com/privacy")!)
                            .frame(minHeight: 44).disabled(saving)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { sourceButtons }
                        VStack(alignment: .leading, spacing: 16) { sourceButtons }
                    }.disabled(saving)
                    if let error { Text(error).foregroundColor(.red).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                }.padding(24)
                // A Mac sheet takes the width its content asks for, so long lines wrap inside the sheet instead.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Brand.background).navigationTitle(L("import_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                Button(action: save) {
                    HStack {
                        if saving { ProgressView().controlSize(.small) }
                        Text(L(activating ? "activate_device" : "import_profile"))
                    }
                }
                .buttonStyle(.borderedProminent).foregroundColor(Brand.ink)
                .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(maxWidth: .infinity).padding(20).background(Brand.background)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { text = ""; dismiss() }.disabled(saving) } }
        }
        .preferredColorScheme(.dark).tint(Brand.cyan)
        .interactiveDismissDisabled(saving)
        #if os(macOS)
        // A fixed width: a long pasted link would otherwise widen the sheet past the window.
        .frame(width: 400).frame(minHeight: 520, idealHeight: 600)
        #endif
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.json, .plainText]) { result in
            do { text = try Self.readFile(result.get()) }
            catch { self.error = L("read_failed") }
        }
        #if os(iOS)
        .sheet(isPresented: $showScanner) { QRScanner { value in text = value; showScanner = false } }
        #endif
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                if activating { try await controller.activateInvitation(text) }
                else { try controller.save(text) }
                text = ""; dismiss()
            } catch let failure as AccessFailure {
                error = L(AccessPresentation.errorKey(failure.code))
                if controller.access?.device.isEmpty == false { text = ""; dismiss() }
            } catch {
                self.error = (error as? ProfileError)?.localizedDescription ?? L("save_failed")
            }
        }
    }

    private var limitedText: Binding<String> {
        Binding(get: { text }, set: { if $0.count <= ConnectionProfile.maximumLength { text = $0; error = nil } })
    }
    @ViewBuilder private var sourceButtons: some View {
        #if os(iOS)
        Button { showScanner = true } label: { Label(L("scan_qr"), systemImage: "qrcode.viewfinder") }
        #endif
        Button { showFile = true } label: { Label(L("open_file"), systemImage: "doc") }
    }
    static func readFile(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: ConnectionProfile.maximumLength * 4 + 1) ?? Data()
        guard data.count <= ConnectionProfile.maximumLength * 4, let value = String(data: data, encoding: .utf8), value.count <= ConnectionProfile.maximumLength else { throw ProfileError.tooLarge }
        return value
    }
}
