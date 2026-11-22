import Foundation

struct AccessHTTPClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let maximumResponseBytes = 256 * 1024
    let appVersion: String?
    private let transport: Transport

    init(appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         transport: @escaping Transport = { try await AccessHTTPClient.send($0) }) {
        self.appVersion = appVersion.flatMap { value in
            value.range(of: "\\A[A-Za-z0-9._+-]{1,32}\\z", options: .regularExpression) != nil ? value : nil
        }
        self.transport = transport
    }

    func request(method: String, path: String, token: String = "", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: Invitation.origin + path)!, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 10)
        request.httpMethod = method
        request.httpBody = body
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let appVersion { request.setValue(appVersion, forHTTPHeaderField: "X-Wayveil-App-Version") }
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw AccessFailure("network_error")
        }
        try Task.checkCancellation()
        guard data.count <= Self.maximumResponseBytes else { throw AccessFailure("network_error") }
        if response.statusCode == 204 { return Data("{}".utf8) }
        guard (200..<300).contains(response.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw AccessFailure(object?["error"] as? String ?? "network_error")
        }
        return data
    }

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: AccessRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw AccessFailure("network_error") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw AccessFailure("network_error") }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class AccessRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
