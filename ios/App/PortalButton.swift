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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var scaledDiameter = 164.0
    @State private var started = Date()
    @State private var motionPhase: TunnelPhase = .disconnected
    @State private var initialPower = 0.0
    @State private var initialBusy = 0.0
    @State private var initialTime = 0.0
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
                TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || scenePhase != .active)) { context in
                    let frame = sample(context.date)
                    PortalEffect(time: Float(frame.time), power: Float(frame.power), busy: Float(frame.busy),
                                 age: Float(frame.age), phase: phase, buttonDiameter: buttonDiameter,
                                 logoBounds: logoBounds, active: scenePhase == .active)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
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
        .task(id: phase) {
            let current = sample(Date())
            initialPower = current.power; initialBusy = current.busy; initialTime = current.time
            started = Date(); motionPhase = phase
        }
    }

    private func sample(_ date: Date) -> (time: Double, power: Double, busy: Double, age: Double) {
        let elapsed = reduceMotion ? 10 : max(0, date.timeIntervalSince(started))
        let blend = reduceMotion ? 1 : 1 - exp(-elapsed * 7)
        let targetPower = motionPhase == .connected ? 1.0 : 0.0
        let targetBusy = motionPhase == .connecting || motionPhase == .reconnecting ? 1.0 : 0.0
        let power = initialPower + (targetPower - initialPower) * blend
        let activity = initialBusy + (targetBusy - initialBusy) * blend
        let speed = motionPhase == .reconnecting ? 0.75 : 1.0
        let time = reduceMotion ? 0 : initialTime + elapsed * (0.28 + activity * 0.72) * speed
        return (time, power, activity, elapsed)
    }
}

private struct PortalLogoBoundsKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
