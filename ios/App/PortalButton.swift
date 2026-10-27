import SwiftUI

enum Brand {
    static let mint = Color(red: 182 / 255, green: 240 / 255, blue: 200 / 255)
    static let background = Color(red: 12 / 255, green: 23 / 255, blue: 28 / 255)
    static let panel = Color(red: 21 / 255, green: 38 / 255, blue: 45 / 255)
    static let muted = Color(red: 154 / 255, green: 175 / 255, blue: 182 / 255)
    static let ready = Color(red: 37 / 255, green: 74 / 255, blue: 73 / 255)
    static let ink = Color(red: 18 / 255, green: 48 / 255, blue: 37 / 255)
}

struct PortalButton: View {
    let phase: TunnelPhase
    let enabled: Bool
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var scaledDiameter = 164.0
    @State private var logoBounds = CGRect.zero
    private var connected: Bool { phase == .connected }
    private var diameter: CGFloat { min(236, scaledDiameter) }

    var body: some View {
        GeometryReader { geometry in
            let side = min(diameter + 128, geometry.size.width)
            let buttonDiameter = min(diameter, side * 0.6)
            ZStack {
                Circle().stroke(Brand.mint.opacity(0.12), lineWidth: 1)
                    .frame(width: buttonDiameter * 1.37, height: buttonDiameter * 1.37)
                    .accessibilityHidden(true)
                PortalEffect(phase: phase, buttonDiameter: buttonDiameter, logoBounds: logoBounds, active: scenePhase == .active)
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
                    .foregroundColor(Brand.mint)
                    .frame(width: buttonDiameter, height: buttonDiameter)
                    .overlay(Circle().stroke(Brand.mint.opacity(connected ? 0.29 : 0.12), lineWidth: 1))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
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

private struct PortalLogoBoundsKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
