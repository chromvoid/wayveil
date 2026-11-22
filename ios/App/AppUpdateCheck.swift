import Foundation
#if os(iOS)
import Combine
import StoreKit
import UIKit
#endif

struct AppStoreVersion: Decodable {
    let version: String
    let minimumOsVersion: String?

    static func parse(_ data: Data) throws -> AppStoreVersion? {
        struct Response: Decodable { let results: [AppStoreVersion] }
        return try JSONDecoder().decode(Response.self, from: data).results.first
    }

    func isUpdateAvailable(currentVersion: String, systemVersion: String) -> Bool {
        guard AppUpdateCheck.isNewer(version, than: currentVersion) else { return false }
        guard let minimumOsVersion else { return true }
        guard let comparison = AppUpdateCheck.compare(minimumOsVersion, systemVersion) else { return false }
        return comparison != .orderedDescending
    }
}

enum AppUpdateCheck {
    static func isNewer(_ version: String, than current: String) -> Bool {
        compare(version, current) == .orderedDescending
    }

    static func countries(for storefront: String?) -> [String] {
        switch storefront {
        case "ARM": return ["am"]
        case "RUS": return ["ru"]
        case "NLD": return ["nl"]
        default: return ["ru", "am", "nl"]
        }
    }

    fileprivate static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        func components(_ version: String) -> [Int]? {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            var numbers: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = Int(part) else { return nil }
                numbers.append(number)
            }
            return numbers
        }
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }
}

#if os(iOS)
@MainActor
final class AppUpdateChecker: NSObject, ObservableObject, @preconcurrency SKStoreProductViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    @Published var available = false
    private var lastSuccessfulCheck: Date?
    private var checking = false
    private var storeController: SKStoreProductViewController?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    func check() async {
        guard !checking, lastSuccessfulCheck.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true else { return }
        checking = true
        defer { checking = false }
        let storefront = await Storefront.current
        do {
            for country in AppUpdateCheck.countries(for: storefront?.countryCode) {
                let url = URL(string: "https://itunes.apple.com/lookup?id=6827036420&country=\(country)")!
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                guard let version = try AppStoreVersion.parse(data) else { continue }
                available = version.isUpdateAvailable(
                    currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    systemVersion: UIDevice.current.systemVersion)
                lastSuccessfulCheck = Date()
                return
            }
        } catch { }
    }

    func openAppStore() {
        guard storeController == nil, Self.topViewController() != nil else { return }
        let store = SKStoreProductViewController()
        storeController = store
        store.delegate = self
        store.loadProduct(withParameters: [SKStoreProductParameterITunesItemIdentifier: 6827036420]) { [weak self] loaded, error in
            Task { @MainActor in
                guard let self else { return }
                guard loaded, error == nil else {
                    self.storeController = nil
                    UIApplication.shared.open(URL(string: "itms-apps://apps.apple.com/app/id6827036420")!)
                    return
                }
                guard let presenter = Self.topViewController() else { self.storeController = nil; return }
                presenter.present(store, animated: true)
                store.presentationController?.delegate = self
            }
        }
    }

    func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
        viewController.dismiss(animated: true) { self.storeController = nil }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        storeController = nil
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let controller = top {
            if let presented = controller.presentedViewController { top = presented }
            else if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController { top = visible }
            else if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController { top = selected }
            else { return controller }
        }
        return nil
    }
}
#endif
