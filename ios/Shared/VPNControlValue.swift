import NetworkExtension

struct VPNControlValue {
    let isOn: Bool
    let statusKey: String
}

func vpnControlValue(for status: NEVPNStatus?) -> VPNControlValue {
    switch status {
    case .connecting?:
        return VPNControlValue(isOn: true, statusKey: "connecting")
    case .connected?:
        return VPNControlValue(isOn: true, statusKey: "connected")
    case .reasserting?:
        return VPNControlValue(isOn: true, statusKey: "reconnecting")
    case .disconnecting?:
        return VPNControlValue(isOn: false, statusKey: "stopping")
    case .disconnected?, .invalid?, nil:
        return VPNControlValue(isOn: false, statusKey: "disconnected")
    @unknown default:
        return VPNControlValue(isOn: false, statusKey: "disconnected")
    }
}
