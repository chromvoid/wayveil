import SwiftUI

enum Brand {
    // ChromVoid's dark palette (hue 232 in OKLCH); its HEX fallbacks are in chromvoid's business/brand/color-system.md.
    static let cyan = Color(red: 132 / 255, green: 213 / 255, blue: 255 / 255)
    static let background = Color(red: 11 / 255, green: 13 / 255, blue: 16 / 255)
    static let pageTop = Color(red: 14 / 255, green: 45 / 255, blue: 59 / 255)
    static let panel = Color(red: 20 / 255, green: 27 / 255, blue: 34 / 255)
    static let text = Color(red: 237 / 255, green: 243 / 255, blue: 248 / 255)
    static let muted = Color(red: 165 / 255, green: 180 / 255, blue: 194 / 255)
    static let ready = Color(red: 18 / 255, green: 58 / 255, blue: 77 / 255)
    static let ink = Color(red: 7 / 255, green: 44 / 255, blue: 60 / 255)
}

struct PortalButton: View {
    let phase: TunnelPhase
    let enabled: Bool
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var scaledDiameter = 164.0
    @State private var logoBounds = CGRect.zero
    @State private var pressed = false
    private var diameter: CGFloat { min(236, scaledDiameter) }

    var body: some View {
        GeometryReader { geometry in
            let side = min(diameter + 128, geometry.size.width)
            let buttonDiameter = min(diameter, side * 0.6)
            ZStack {
                Circle().stroke(Brand.cyan.opacity(0.12), lineWidth: 1)
                    .frame(width: buttonDiameter * 1.37, height: buttonDiameter * 1.37)
                    .accessibilityHidden(true)
                PortalEffect(phase: phase, buttonDiameter: buttonDiameter, logoBounds: logoBounds, active: scenePhase == .active,
                             pressed: pressed)
                    .allowsHitTesting(false).accessibilityHidden(true)
                Button(action: action) {
                    VStack(spacing: 8) {
                        Color.clear.frame(width: buttonDiameter * 0.38, height: buttonDiameter * 0.38)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: PortalLogoBoundsKey.self,
                                                       value: proxy.frame(in: .named("portalStage")))
                            })
                            .accessibilityHidden(true)
                        Text(L(phase.running ? "disconnect" : "connect"))
                            .font(.subheadline.weight(.semibold)).multilineTextAlignment(.center).padding(.horizontal, 12)
                    }
                    .foregroundColor(Brand.cyan)
                    .frame(width: buttonDiameter, height: buttonDiameter)
                    // The ring reads as the edge of the button, so a tap anywhere up to its outer edge counts.
                    .frame(width: buttonDiameter * 1.5, height: buttonDiameter * 1.5)
                    .contentShape(Circle())
                }
                .buttonStyle(PortalPressStyle(pressed: $pressed))
                .disabled(!enabled || phase == .stopping)
                .accessibilityLabel(L(phase.running ? "disconnect" : "connect"))
                .accessibilityValue(L(phase.rawValue))
            }
            .frame(width: side, height: side)
            .coordinateSpace(name: "portalStage")
            .onPreferenceChange(PortalLogoBoundsKey.self) { logoBounds = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: diameter + 128)
    }
}

/// Shows no pressed look of its own: it hands the press to the portal ring, which answers it.
private struct PortalPressStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed = $0 }
    }
}

private struct PortalLogoBoundsKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
