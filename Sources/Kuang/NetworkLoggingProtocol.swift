import Foundation
import os

/// Identifies which call — and which attempt of that call — a log entry
/// belongs to, so concurrent traffic can be told apart in the log output.
public struct NetworkLogContext: Sendable {
    /// Short identifier shared by every log entry (request, response, error,
    /// retry) of a single `request(endpoint:)` call, across all its attempts.
    public let requestID: String
    /// 1-based attempt number: `1` is the first try, `2` the first retry…
    public let attempt: Int

    /// - Parameters:
    ///   - requestID: identifier shared by all entries of one call; see
    ///     ``makeRequestID()``.
    ///   - attempt: 1-based attempt number.
    public init(requestID: String, attempt: Int = 1) {
        self.requestID = requestID
        self.attempt = attempt
    }

    /// Generates a short random identifier suitable for `requestID`.
    public static func makeRequestID() -> String {
        String(UUID().uuidString.prefix(8))
    }
}

/// Receives every request, response, error and retry decision handled by
/// ``HTTPClient``. Implement it to route traffic to your own sink; the
/// package ships ``ConsoleNetworkLogger`` and ``DisabledNetworkLogger``.
public protocol NetworkLoggingProtocol: Sendable {
    /// Called with the prepared request just before it is sent.
    func log(request: URLRequest, context: NetworkLogContext)
    /// Called for every HTTP response — including non-2xx, which the client
    /// only turns into an error after logging. `duration` is the elapsed time
    /// of this attempt, from sending the request to receiving the response.
    func log(responseData: Data, response: HTTPURLResponse, duration: TimeInterval, context: NetworkLogContext)
    /// `request` is the prepared request of the failing attempt, or `nil` when
    /// the failure happened before one could be built (URL, auth, encoding).
    func log(error: Error, request: URLRequest?, context: NetworkLogContext)
    /// Called when an interceptor decided to retry a failed attempt. Never
    /// called with ``RetryDecision/doNotRetry``.
    func log(retryDecision: RetryDecision, dueTo error: NetworkError, context: NetworkLogContext)
}

/// The default logger — discards every entry.
public struct DisabledNetworkLogger: NetworkLoggingProtocol {
    /// Creates the logger.
    public init() {}

    public func log(request: URLRequest, context: NetworkLogContext) {}
    public func log(responseData: Data, response: HTTPURLResponse, duration: TimeInterval, context: NetworkLogContext) {}
    public func log(error: Error, request: URLRequest?, context: NetworkLogContext) {}
    public func log(retryDecision: RetryDecision, dueTo error: NetworkError, context: NetworkLogContext) {}
}

/// Verbose traffic logger built on `os.Logger`.
///
/// Every entry is tagged `[requestID #attempt]` so interleaved concurrent
/// requests can be correlated. Responses log at `debug` for status < 400 and
/// at `error` otherwise.
///
/// Sensitive header values (`Authorization` by default) are replaced with
/// `<redacted>` before logging. Request and response bodies are logged with
/// `.private` privacy — visible while a debugger is attached, hidden in
/// production device logs — since payloads routinely carry credentials and
/// tokens. Bodies longer than `maxBodyLength` characters are truncated.
public struct ConsoleNetworkLogger: NetworkLoggingProtocol {

    private let logger: os.Logger
    private let redactedHeaders: Set<String>
    private let maxBodyLength: Int

    /// - Parameters:
    ///   - subsystem: `os.Logger` subsystem; defaults to the app's bundle
    ///     identifier so entries group under the app in Console.app.
    ///   - category: `os.Logger` category.
    ///   - redactedHeaders: header names (case-insensitive) whose values are
    ///     hidden from the log output.
    ///   - maxBodyLength: bodies longer than this (in characters) are logged
    ///     truncated, and skip pretty-printing entirely.
    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "Kuang",
        category: String = "HTTPClient",
        redactedHeaders: Set<String> = ["Authorization"],
        maxBodyLength: Int = 10_000
    ) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
        self.redactedHeaders = Set(redactedHeaders.map { $0.lowercased() })
        self.maxBodyLength = max(0, maxBodyLength)
    }

    public func log(request: URLRequest, context: NetworkLogContext) {
        guard let url = request.url else { return }
        var head = """
        \(url.absoluteString)
        Method: \(request.httpMethod ?? "-")
        """
        let headers = request.allHTTPHeaderFields ?? [:]
        if !headers.isEmpty {
            head += "\n\nHeaders:\n\(sanitized(headers))"
        }
        if let body = bodyDescription(from: request.httpBody) {
            logger.debug("🚀 Request \(tag(context), privacy: .public)\n\(head, privacy: .public)\n\nBody:\n\(body, privacy: .private)")
        } else {
            logger.debug("🚀 Request \(tag(context), privacy: .public)\n\(head, privacy: .public)")
        }
    }

    public func log(responseData: Data, response: HTTPURLResponse, duration: TimeInterval, context: NetworkLogContext) {
        let failed = response.statusCode >= 400
        let level: OSLogType = failed ? .error : .debug
        let emoji = failed ? "⚠️" : "✅"
        let head = """
        \(response.url?.absoluteString ?? "-")
        Status Code: \(response.statusCode) (\(formatted(duration)))
        """
        if let body = bodyDescription(from: responseData) {
            logger.log(level: level, "\(emoji, privacy: .public) Response \(tag(context), privacy: .public)\n\(head, privacy: .public)\n\nBody:\n\(body, privacy: .private)")
        } else {
            logger.log(level: level, "\(emoji, privacy: .public) Response \(tag(context), privacy: .public)\n\(head, privacy: .public)")
        }
    }

    public func log(error: Error, request: URLRequest?, context: NetworkLogContext) {
        let target = request.map { "\($0.httpMethod ?? "-") \($0.url?.absoluteString ?? "-")" } ?? "(request not built)"
        logger.error("❌ Network Error \(tag(context), privacy: .public)\n\(target, privacy: .public)\n\(String(describing: error), privacy: .public)")
    }

    public func log(retryDecision: RetryDecision, dueTo error: NetworkError, context: NetworkLogContext) {
        let timing: String
        switch retryDecision {
        case .retry:
            timing = "immediately"
        case .retryAfter(let delay):
            timing = "in \(String(format: "%.2f", delay))s"
        case .doNotRetry:
            return
        }
        logger.debug("🔁 Retry \(tag(context), privacy: .public) attempt \(context.attempt + 1, privacy: .public) \(timing, privacy: .public) — after: \(String(describing: error), privacy: .public)")
    }

    private func tag(_ context: NetworkLogContext) -> String {
        "[\(context.requestID) #\(context.attempt)]"
    }

    private func formatted(_ duration: TimeInterval) -> String {
        String(format: "%.0f ms", duration * 1_000)
    }

    /// Internal for testing.
    func sanitized(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, header in
            result[header.key] = redactedHeaders.contains(header.key.lowercased())
                ? "<redacted>"
                : header.value
        }
    }

    /// `nil` when there is nothing to log, so callers can omit the BODY
    /// section entirely. Internal for testing.
    func bodyDescription(from data: Data?) -> String? {
        guard let data, !data.isEmpty else {
            return nil
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            return "<binary body: \(data.count) bytes>"
        }
        // Pretty-printing re-serializes the whole payload; not worth it for a
        // body that is about to be truncated anyway.
        let text = raw.count > maxBodyLength ? raw : (prettyPrintedJSON(from: data) ?? raw)

        guard text.count > maxBodyLength else {
            return text
        }
        return text.prefix(maxBodyLength) + "\n… truncated (\(data.count) bytes total)"
    }

    private func prettyPrintedJSON(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
            let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }

        return prettyString
    }
}
