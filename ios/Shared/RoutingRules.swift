import Foundation
import Darwin

enum RoutingRuleError: String, Error, LocalizedError {
    case formatUnsupported = "format_unsupported"
    case invalidDocument = "invalid_document"
    case invalidVersion = "invalid_version"
    case invalidCategory = "invalid_category"
    case invalidDomain = "invalid_domain"
    case tldNotAllowed = "tld_not_allowed"
    case duplicateEntry = "duplicate_entry"
    case tooManyEntries = "too_many_entries"
    case tooLarge = "too_large"
    case nameInOtherList = "name_in_other_list"

    var errorDescription: String? {
        switch self {
        case .invalidDomain, .tldNotAllowed: return "Enter a valid domain name or website address."
        case .duplicateEntry: return "This domain is already in the list."
        case .nameInOtherList: return "This domain is already in the other list."
        case .tooManyEntries: return "The routing list has too many entries."
        case .tooLarge: return "The routing document is too large."
        default: return "The routing document is invalid (\(rawValue))."
        }
    }
}

struct RoutingDocument {
    struct Category {
        let id: String
        let title: [String: String]
        let domainSuffix: [String]
        let domain: [String]
    }

    let version: Int
    let categories: [Category]

    static func bundled(bundle: Bundle = .main) throws -> RoutingDocument {
        guard let url = bundle.url(forResource: "default-rules", withExtension: "json") else {
            throw RoutingRuleError.invalidDocument
        }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> RoutingDocument {
        let fields = try RoutingJSON.document(data, keys: ["format", "version", "categories"])
        guard let version = RoutingJSON.integer(fields["version"]), version > 0 else { throw RoutingRuleError.invalidVersion }
        guard let rawCategories = fields["categories"] as? [[String: Any]] else { throw RoutingRuleError.invalidDocument }
        guard (1...32).contains(rawCategories.count) else { throw RoutingRuleError.invalidCategory }
        var ids = Set<String>()
        var entries = Set<String>()
        var categories: [Category] = []
        for fields in rawCategories {
            try RoutingJSON.checkKeys(fields, allowed: ["id", "title", "domain_suffix", "domain"])
            if let id = fields["id"], !(id is String) { throw RoutingRuleError.invalidDocument }
            let id = fields["id"] as? String ?? ""
            let title: [String: String]
            if fields["title"] == nil || fields["title"] is NSNull {
                title = [:]
            } else {
                guard let titles = fields["title"] as? [String: String] else { throw RoutingRuleError.invalidDocument }
                try RoutingJSON.checkKeys(titles, allowed: ["ru", "en"])
                title = titles
            }
            let suffixes = try RoutingJSON.strings(fields, key: "domain_suffix", optional: true)
            let domains = try RoutingJSON.strings(fields, key: "domain", optional: true)
            guard (1...32).contains(id.utf8.count), id.utf8.allSatisfy({ RoutingJSON.isLetterOrDigit($0) || $0 == 45 }),
                  ids.insert(id).inserted, title.count == 2,
                  title.values.allSatisfy({ (1...64).contains($0.unicodeScalars.count) }),
                  !suffixes.isEmpty || !domains.isEmpty else { throw RoutingRuleError.invalidCategory }
            for (names, suffix) in [(suffixes, true), (domains, false)] {
                for name in names {
                    try RoutingJSON.validateDomain(name, suffix: suffix)
                    guard entries.insert(name).inserted else { throw RoutingRuleError.duplicateEntry }
                    guard entries.count <= 3000 else { throw RoutingRuleError.tooManyEntries }
                }
            }
            categories.append(Category(id: id, title: title, domainSuffix: suffixes, domain: domains))
        }
        return RoutingDocument(version: version, categories: categories)
    }
}

struct RoutingOverrides: Encodable, Equatable {
    enum List { case direct, proxy }

    static let empty = RoutingOverrides(direct: [], proxy: [])
    let format = 1
    let direct: [String]
    let proxy: [String]

    private init(direct: [String], proxy: [String]) {
        self.direct = direct
        self.proxy = proxy
    }

    static func parse(_ data: Data) throws -> RoutingOverrides {
        let fields = try RoutingJSON.document(data, keys: ["format", "direct", "proxy"])
        let direct = try RoutingJSON.strings(fields, key: "direct")
        let proxy = try RoutingJSON.strings(fields, key: "proxy")
        var entries = Set<String>()
        for names in [direct, proxy] {
            for name in names {
                try RoutingJSON.validateDomain(name, suffix: true)
                guard name.contains(".") else { throw RoutingRuleError.tldNotAllowed }
                guard entries.insert(name).inserted else { throw RoutingRuleError.duplicateEntry }
            }
            guard names.count <= 500 else { throw RoutingRuleError.tooManyEntries }
        }
        return RoutingOverrides(direct: direct, proxy: proxy)
    }

    func adding(_ input: String, to list: List) throws -> RoutingOverrides {
        let name = try RoutingRules.normalizeInput(input)
        let names = list == .direct ? direct : proxy
        let other = list == .direct ? proxy : direct
        guard !other.contains(name) else { throw RoutingRuleError.nameInOtherList }
        guard !names.contains(name) else { throw RoutingRuleError.duplicateEntry }
        guard names.count < 500 else { throw RoutingRuleError.tooManyEntries }
        let updated = RoutingOverrides(direct: list == .direct ? direct + [name] : direct,
                                      proxy: list == .proxy ? proxy + [name] : proxy)
        // Keep stored documents within the same bounds as documents accepted by parse.
        guard try JSONEncoder().encode(updated).count <= RoutingJSON.maximumBytes else { throw RoutingRuleError.tooLarge }
        return updated
    }

    func removing(_ domain: String, from list: List) -> RoutingOverrides {
        RoutingOverrides(direct: list == .direct ? direct.filter { $0 != domain } : direct,
                         proxy: list == .proxy ? proxy.filter { $0 != domain } : proxy)
    }
}

struct RoutingRules: Encodable, Equatable {
    let proxySuffix: [String]
    let directSuffix: [String]
    let directDomain: [String]

    enum CodingKeys: String, CodingKey {
        case proxySuffix = "proxy_suffix"
        case directSuffix = "direct_suffix"
        case directDomain = "direct_domain"
    }

    init(routing: RoutingMode, base: RoutingDocument, overrides: RoutingOverrides) {
        proxySuffix = Array(Set(overrides.proxy)).sorted()
        directSuffix = Array(Set(overrides.direct + (routing == .russianDirect ? base.categories.flatMap(\.domainSuffix) : []))).sorted()
        directDomain = Array(Set(routing == .russianDirect ? base.categories.flatMap(\.domain) : [])).sorted()
    }

    static func normalizeInput(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw RoutingRuleError.invalidDomain }
        var address = text[...]
        if let separator = address.range(of: "://"),
           !address[..<separator.lowerBound].contains(where: { ["/", "?", "#"].contains($0) }) {
            let scheme = address[..<separator.lowerBound].utf8
            guard let first = scheme.first, (65...90).contains(first) || (97...122).contains(first),
                  scheme.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 45, 46].contains($0) }) else {
                throw RoutingRuleError.invalidDomain
            }
            address = address[separator.upperBound...]
        }
        var host = address.prefix { !["/", "?", "#"].contains($0) }
        if let userinfo = host.lastIndex(of: "@") { host = host[host.index(after: userinfo)...] }
        if let port = host.firstIndex(of: ":") { host = host[..<port] }
        var name = host.lowercased().precomposedStringWithCanonicalMapping
        if name.hasPrefix("www.") { name.removeFirst(4) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        name = try labels.map { try asciiLabel(String($0)) }.joined(separator: ".")
        try RoutingJSON.validateDomain(name, suffix: false)
        return name
    }

    // RFC 3492, section 6.3. Encode Unicode labels independently of Foundation's IDN support.
    private static func asciiLabel(_ label: String) throws -> String {
        let scalars = label.unicodeScalars
        guard scalars.contains(where: { !$0.isASCII }) else { return label }
        guard scalars.count <= 63, scalars.first?.value != 45, scalars.last?.value != 45, scalars.allSatisfy({ scalar in
            scalar.value == 45 || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
        }) else { throw RoutingRuleError.invalidDomain }
        let input = scalars.map { Int($0.value) }
        var output = input.filter { $0 < 128 }.map { UInt8($0) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append(45) }
        var n = 128
        var delta = 0
        var bias = 72
        while handled < input.count {
            let next = input.filter { $0 >= n }.min()!
            // At most 63 Unicode scalars (each <= 0x10ffff) keep all arithmetic within Int64.
            delta += (next - n) * (handled + 1)
            n = next
            for scalar in input {
                if scalar < n { delta += 1 }
                if scalar == n {
                    var q = delta
                    var k = 36
                    while true {
                        let threshold = min(26, max(1, k - bias))
                        if q < threshold { break }
                        let digit = threshold + (q - threshold) % (36 - threshold)
                        output.append(UInt8(digit < 26 ? digit + 97 : digit + 22))
                        q = (q - threshold) / (36 - threshold)
                        k += 36
                    }
                    output.append(UInt8(q < 26 ? q + 97 : q + 22))
                    var adjusted = delta / (handled == basicCount ? 700 : 2)
                    adjusted += adjusted / (handled + 1)
                    var shift = 0
                    while adjusted > 455 { adjusted /= 35; shift += 36 }
                    bias = shift + 36 * adjusted / (adjusted + 38)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return "xn--" + String(decoding: output, as: UTF8.self)
    }
}

private enum RoutingJSON {
    static let maximumBytes = 65_536

    static func checkKeys<T>(_ fields: [String: T], allowed: Set<String>) throws {
        guard Set(fields.keys).isSubset(of: allowed) else { throw RoutingRuleError.invalidDocument }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return number as? Int
    }

    static func document(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard data.count <= maximumBytes else { throw RoutingRuleError.tooLarge }
        guard String(data: data, encoding: .utf8) != nil,
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw RoutingRuleError.invalidDocument }
        try checkKeys(fields, allowed: keys)
        guard let format = integer(fields["format"]) else { throw RoutingRuleError.invalidDocument }
        guard format == 1 else { throw RoutingRuleError.formatUnsupported }
        return fields
    }

    static func strings(_ fields: [String: Any], key: String, optional: Bool = false) throws -> [String] {
        if fields[key] == nil && optional { return [] }
        guard let values = fields[key] as? [String] else { throw RoutingRuleError.invalidDocument }
        return values
    }

    static func isLetterOrDigit(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }

    static func validateDomain(_ name: String, suffix: Bool) throws {
        guard (1...253).contains(name.utf8.count) else { throw RoutingRuleError.invalidDomain }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET, name, &ipv4) != 1, inet_pton(AF_INET6, name, &ipv6) != 1 else { throw RoutingRuleError.invalidDomain }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.utf8.count), label.utf8.first != 45, label.utf8.last != 45,
                  label.utf8.allSatisfy({ isLetterOrDigit($0) || $0 == 45 }) else { throw RoutingRuleError.invalidDomain }
        }
        if labels.count == 1 {
            guard suffix else { throw RoutingRuleError.invalidDomain }
            guard ["ru", "su", "xn--p1ai"].contains(name) else { throw RoutingRuleError.tldNotAllowed }
        }
    }
}
