import Foundation

struct TunnelTraffic: Codable, Equatable {
    var downloadBytes: Int64 = 0
    var uploadBytes: Int64 = 0

    mutating func add(_ traffic: TunnelTraffic) {
        downloadBytes += traffic.downloadBytes
        uploadBytes += traffic.uploadBytes
    }
}

struct TunnelMetricsTotals: Codable, Equatable {
    var total: TunnelTraffic
    var month: TunnelTraffic
    let trackingStartedAt: Date
    var monthComponents: DateComponents
}

struct TunnelMetricsSnapshot: Codable, Equatable {
    let capturedAt: Date
    let sessionStartedAt: Date
    let currentLatencyMs: Double?
    let medianLatencyMs: Double?
    let downloadMedianBps: Double
    let downloadPeakBps: Double
    let session: TunnelTraffic
    let month: TunnelTraffic
    let total: TunnelTraffic
    let trackingStartedAt: Date
    let monthComponents: DateComponents
    let engineDownloadBytes: Int64
    let engineUploadBytes: Int64

    func monthTraffic(at date: Date = Date(), calendar: Calendar = .current) -> TunnelTraffic {
        calendar.dateComponents([.era, .year, .month], from: date) == monthComponents ? month : TunnelTraffic()
    }

    func liveSpeed(since previous: TunnelMetricsSnapshot) -> (downloadBps: Double, uploadBps: Double)? {
        let elapsed = capturedAt.timeIntervalSince(previous.capturedAt)
        guard sessionStartedAt == previous.sessionStartedAt, elapsed > 0,
              engineDownloadBytes >= previous.engineDownloadBytes, engineUploadBytes >= previous.engineUploadBytes else { return nil }
        return (Double(engineDownloadBytes - previous.engineDownloadBytes) / elapsed,
                Double(engineUploadBytes - previous.engineUploadBytes) / elapsed)
    }
}

struct TunnelMetrics {
    private(set) var totals: TunnelMetricsTotals
    private let sessionStartedAt: Date
    private var session = TunnelTraffic()
    private var previous = TunnelTraffic()
    private var latencies: [Double] = []

    init(totals: TunnelMetricsTotals? = nil, at date: Date = Date(), calendar: Calendar = .current) {
        sessionStartedAt = date
        self.totals = totals ?? TunnelMetricsTotals(total: TunnelTraffic(), month: TunnelTraffic(),
            trackingStartedAt: date, monthComponents: calendar.dateComponents([.era, .year, .month], from: date))
        updateMonth(at: date, calendar: calendar)
    }

    mutating func recordLatency(_ milliseconds: Double) {
        latencies.append(milliseconds)
        if latencies.count > 20 { latencies.removeFirst() }
    }

    mutating func recordTraffic(downloadBytes: Int64, uploadBytes: Int64, at date: Date = Date(), calendar: Calendar = .current) {
        updateMonth(at: date, calendar: calendar)
        let delta = unrecordedTraffic(downloadBytes: downloadBytes, uploadBytes: uploadBytes)
        session.add(delta)
        totals.month.add(delta)
        totals.total.add(delta)
        previous = TunnelTraffic(downloadBytes: downloadBytes, uploadBytes: uploadBytes)
    }

    func snapshot(downloadMedianBps: Double, downloadPeakBps: Double, engineDownloadBytes: Int64,
                  engineUploadBytes: Int64, at date: Date = Date()) -> TunnelMetricsSnapshot {
        let sorted = latencies.sorted()
        let median: Double?
        if sorted.isEmpty { median = nil }
        else if sorted.count.isMultiple(of: 2) { median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 }
        else { median = sorted[sorted.count / 2] }
        let delta = unrecordedTraffic(downloadBytes: engineDownloadBytes, uploadBytes: engineUploadBytes)
        var session = session, month = totals.month, total = totals.total
        session.add(delta)
        month.add(delta)
        total.add(delta)
        return TunnelMetricsSnapshot(capturedAt: date, sessionStartedAt: sessionStartedAt,
            currentLatencyMs: latencies.last, medianLatencyMs: median,
            downloadMedianBps: downloadMedianBps, downloadPeakBps: downloadPeakBps,
            session: session, month: month, total: total, trackingStartedAt: totals.trackingStartedAt,
            monthComponents: totals.monthComponents, engineDownloadBytes: engineDownloadBytes, engineUploadBytes: engineUploadBytes)
    }

    private func unrecordedTraffic(downloadBytes: Int64, uploadBytes: Int64) -> TunnelTraffic {
        TunnelTraffic(
            downloadBytes: downloadBytes >= previous.downloadBytes ? downloadBytes - previous.downloadBytes : downloadBytes,
            uploadBytes: uploadBytes >= previous.uploadBytes ? uploadBytes - previous.uploadBytes : uploadBytes)
    }

    private mutating func updateMonth(at date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.era, .year, .month], from: date)
        guard components != totals.monthComponents else { return }
        totals.month = TunnelTraffic()
        totals.monthComponents = components
    }
}

enum TunnelMetricsFormat {
    static func bytes(_ bytes: Int64, locale: Locale = .current) -> String {
        let units = isRussian(locale) ? ["Б", "КБ", "МБ", "ГБ", "ТБ"] : ["B", "KB", "MB", "GB", "TB"]
        return scaled(Double(bytes), base: 1024, units: units, locale: locale)
    }

    static func speed(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let units = isRussian(locale) ? ["Кбит/с", "Мбит/с", "Гбит/с"] : ["Kbit/s", "Mbit/s", "Gbit/s"]
        return scaled(bytesPerSecond * 8 / 1000, base: 1000, units: units, locale: locale)
    }

    static func latency(_ milliseconds: Double, locale: Locale = .current) -> String {
        "\(number(milliseconds, fractionDigits: 0, locale: locale)) \(isRussian(locale) ? "мс" : "ms")"
    }

    private static func scaled(_ value: Double, base: Double, units: [String], locale: Locale) -> String {
        var amount = value
        var index = 0
        while amount.rounded() >= base && index < units.count - 1 {
            amount /= base
            index += 1
        }
        let fractionDigits = amount > 0 && (amount * 10).rounded() / 10 < 100 ? 1 : 0
        return "\(number(amount, fractionDigits: fractionDigits, locale: locale)) \(units[index])"
    }

    private static func number(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value))!
    }

    private static func isRussian(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "ru"
    }
}
