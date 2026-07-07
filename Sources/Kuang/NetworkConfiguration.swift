import Foundation

/// Immutable networking configuration.
///
/// Marked `@unchecked Sendable` because `JSONEncoder`/`JSONDecoder` are reference
/// types that are not themselves `Sendable`. The configuration never mutates them
/// after `init`, so it is safe to share across concurrency domains.
public struct NetworkConfiguration: @unchecked Sendable {
    /// Root URL every endpoint path is appended to.
    public let baseURL: URL
    /// Headers applied to every request. Endpoint and authorization headers
    /// win on key collisions.
    public let defaultHeaders: [String: String]
    /// Encodes `.encodable` request bodies.
    public let encoder: JSONEncoder
    /// Decodes response bodies.
    public let decoder: JSONDecoder
    /// Hard cap on the total number of attempts per request (first try included),
    /// regardless of what interceptors decide. Guards against a misbehaving
    /// interceptor retrying forever. Clamped to at least 1.
    public let maxAttempts: Int
    /// Extracts the user-facing message carried by HTTP error responses.
    public let errorMessageParser: ErrorMessageParsingProtocol

    public init(
        baseURL: URL,
        defaultHeaders: [String: String] = [:],
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        maxAttempts: Int = 10,
        errorMessageParser: ErrorMessageParsingProtocol = DefaultErrorMessageParser()
    ) {
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
        self.encoder = encoder
        self.decoder = decoder
        self.maxAttempts = max(1, maxAttempts)
        self.errorMessageParser = errorMessageParser
    }
}
