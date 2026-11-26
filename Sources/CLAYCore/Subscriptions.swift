#if os(macOS) || os(iOS)
import Foundation

public enum SubscriptionError: LocalizedError, Equatable {
    case invalidURL, insecureRedirect, network, httpStatus(Int), tooLarge, invalidEncoding, noSupportedProfiles

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 HTTPS 订阅地址（本机回环地址可用 HTTP）。"
        case .insecureRedirect: return "订阅服务返回了 CLAY 无法安全跟随的重定向。"
        case .network: return "未能下载订阅，请检查网络或地址后重试。"
        case .httpStatus(let status): return "订阅服务返回 HTTP \(status)，请检查地址是否仍有效。"
        case .tooLarge: return "订阅内容超过 2 MiB，无法导入。"
        case .invalidEncoding: return "订阅内容不是有效的 UTF-8 文本。"
        case .noSupportedProfiles: return "订阅中没有 CLAY 能导入的节点。"
        }
    }
}

public enum SubscriptionImporter {
    public static func validatedURL(_ text: String) throws -> URL {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.utf8.count <= 8_192,
              address.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: address), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
              let url = parts.url else { throw SubscriptionError.invalidURL }
        return url
    }

    public static func parse(_ content: String) -> ImportResult {
        let text = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        return ProfileImporter.read(text)
    }

    public static func fetch(_ url: URL) async throws -> (content: String, imported: ImportResult) {
        let url = try validatedURL(url.absoluteString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: SubscriptionRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse else { throw SubscriptionError.network }
            guard (200..<300).contains(http.statusCode), http.statusCode != 206 else {
                if [301, 302, 303, 307, 308].contains(http.statusCode), http.value(forHTTPHeaderField: "Location") != nil {
                    throw SubscriptionError.insecureRedirect
                }
                throw SubscriptionError.httpStatus(http.statusCode)
            }
            let limit = ProfileImporter.maxBytes
            guard http.expectedContentLength <= Int64(limit) else { throw SubscriptionError.tooLarge }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < limit else { throw SubscriptionError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard let content = String(data: data, encoding: .utf8) else { throw SubscriptionError.invalidEncoding }
            let imported = parse(content)
            guard !imported.profiles.isEmpty else { throw SubscriptionError.noSupportedProfiles }
            return (content, imported)
        } catch let error as SubscriptionError {
            throw error
        } catch {
            // Foundation failures may contain the full subscription URL, including its credentials.
            if Task.isCancelled { throw CancellationError() }
            throw SubscriptionError.network
        }
    }
}

private final class SubscriptionRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let address = request.url?.absoluteString, let destination = try? SubscriptionImporter.validatedURL(address),
              let source = response.url, let scheme = source.scheme?.lowercased(), scheme == destination.scheme?.lowercased(),
              source.host?.lowercased() == destination.host?.lowercased(),
              (source.port ?? (scheme == "https" ? 443 : 80)) == (destination.port ?? (scheme == "https" ? 443 : 80)) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
#endif
