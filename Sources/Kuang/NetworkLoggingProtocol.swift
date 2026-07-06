import Foundation
import os

public protocol NetworkLoggingProtocol: Sendable {
    func log(request: URLRequest)
    func log(responseData: Data, response: HTTPURLResponse)
    func log(error: Error, request: URLRequest?)
}

public struct DisabledNetworkLogger: NetworkLoggingProtocol {
    public init() {}

    public func log(request: URLRequest) {}
    public func log(responseData: Data, response: HTTPURLResponse) {}
    public func log(error: Error, request: URLRequest?) {}
}

/// Verbose traffic logger built on `os.Logger`.
///
/// Sensitive header values (`Authorization` by default) are replaced with
/// `<redacted>` before logging. Request and response bodies are logged with
/// `.private` privacy — visible while a debugger is attached, hidden in
/// production device logs — since payloads routinely carry credentials and
/// tokens.
public struct ConsoleNetworkLogger: NetworkLoggingProtocol {

    private static let logger = os.Logger(subsystem: "Kuang", category: "HTTPClient")

    private let redactedHeaders: Set<String>

    /// - Parameter redactedHeaders: header names (case-insensitive) whose
    ///   values are hidden from the log output.
    public init(redactedHeaders: Set<String> = ["Authorization"]) {
        self.redactedHeaders = Set(redactedHeaders.map { $0.lowercased() })
    }

    public func log(request: URLRequest) {
        guard let url = request.url else { return }
        let head = """
        \(url.absoluteString)
        METHOD: \(request.httpMethod ?? "-")

        HEADERS:
        \(sanitized(request.allHTTPHeaderFields ?? [:]))
        """
        let body = prettyPrintedBody(from: request.httpBody)
        Self.logger.debug("🚀 REQUEST\n\(head, privacy: .public)\n\nBODY:\n\(body, privacy: .private)")
    }

    public func log(responseData: Data, response: HTTPURLResponse) {
        let body = prettyPrintedJSON(from: responseData)
        Self.logger.debug("✅ RESPONSE\nSTATUS CODE: \(response.statusCode, privacy: .public)\n\nJSON:\n\(body, privacy: .private)")
    }

    public func log(error: Error, request: URLRequest?) {
        Self.logger.error("❌ NETWORK ERROR: \(error.localizedDescription, privacy: .public)")
    }

    /// Internal for testing.
    func sanitized(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, header in
            result[header.key] = redactedHeaders.contains(header.key.lowercased())
                ? "<redacted>"
                : header.value
        }
    }

    private func prettyPrintedJSON(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
            let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return String(data: data, encoding: .utf8) ?? "Invalid JSON"
        }

        return prettyString
    }

    private func prettyPrintedBody(from data: Data?) -> String {
        guard let data else {
            return "Empty Body"
        }

        return prettyPrintedJSON(from: data)
    }
}
