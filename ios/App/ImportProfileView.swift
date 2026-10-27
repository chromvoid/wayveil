import SwiftUI
import UniformTypeIdentifiers

struct ImportProfileView: View {
    @ObservedObject var controller: VPNController
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @State private var showFile = false
    @State private var showScanner = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L("import_hint")).foregroundColor(Brand.muted)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("profile_input")).font(.caption).foregroundColor(Brand.muted)
                        SecureField(L("profile_input"), text: limitedText)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(.vertical, 20)
                    }
                    .padding(16).background(Brand.panel, in: RoundedRectangle(cornerRadius: 16))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { sourceButtons }
                        VStack(alignment: .leading, spacing: 16) { sourceButtons }
                    }
                    if let error { Text(error).foregroundColor(.red).font(.subheadline) }
                }.padding(24)
            }
            .background(Brand.background).navigationTitle(L("import_title")).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(L("import_profile")) {
                    do { try controller.save(text); text = ""; dismiss() }
                    catch { self.error = (error as? ProfileError)?.localizedDescription ?? L("save_failed") }
                }
                .buttonStyle(.borderedProminent).foregroundColor(Brand.ink).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(maxWidth: .infinity).padding(20).background(Brand.background)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { text = ""; dismiss() } } }
        }
        .preferredColorScheme(.dark).tint(Brand.mint)
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.json, .plainText]) { result in
            do { text = try Self.readFile(result.get()) }
            catch { self.error = L("read_failed") }
        }
        .sheet(isPresented: $showScanner) { QRScanner { value in text = value; showScanner = false } }
    }

    private var limitedText: Binding<String> {
        Binding(get: { text }, set: { if $0.count <= ConnectionProfile.maximumLength { text = $0; error = nil } })
    }
    @ViewBuilder private var sourceButtons: some View {
        Button { showScanner = true } label: { Label(L("scan_qr"), systemImage: "qrcode.viewfinder") }
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
