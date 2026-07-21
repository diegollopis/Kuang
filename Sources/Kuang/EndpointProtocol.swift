import Foundation

/// A type-safe description of one API endpoint.
///
/// Conform an `enum` — one case per operation — and ``HTTPClient`` builds the
/// `URLRequest` from it. Only ``path`` and ``method`` are required; the other
/// requirements have sensible defaults declared in a protocol extension.
public protocol EndpointProtocol: Sendable {
    /// Path relative to ``NetworkConfiguration/baseURL``, e.g. `"/specialists"`.
    /// A leading slash is optional.
    var path: String { get }
    /// HTTP verb of the request.
    var method: HTTPMethod { get }
    /// The request body to send. Defaults to ``RequestTask/plain`` (no body).
    var task: RequestTask { get }
    /// Endpoint-specific headers, merged over the configuration's
    /// `defaultHeaders` and winning on key collisions. Defaults to empty.
    var headers: [String: String] { get }
    /// Query items appended to the URL. Defaults to empty.
    var queryItems: [URLQueryItem] { get }
    /// How the request is authorized. Defaults to ``AuthorizationType/none``.
    var authorizationType: AuthorizationType { get }
    /// Seconds the request may go without receiving data before failing with
    /// a timeout; `nil` keeps the session's default. The clock resets whenever
    /// data arrives, so streamed responses stay alive as long as chunks keep
    /// flowing. Defaults to `nil`.
    var timeout: TimeInterval? { get }
}

public extension EndpointProtocol {
    var task: RequestTask { .plain }
    var headers: [String: String] { [:] }
    var queryItems: [URLQueryItem] { [] }
    var authorizationType: AuthorizationType { .none }
    var timeout: TimeInterval? { nil }
}
