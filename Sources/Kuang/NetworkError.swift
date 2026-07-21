import Foundation

/// The single error type thrown by ``HTTPClient``.
///
/// Transport problems, request-building failures and non-2xx status codes all
/// map here; task cancellation is the one exception and propagates as Swift's
/// `CancellationError`. For HTTP errors, `message` carries the server-provided
/// text extracted by the configuration's ``ErrorMessageParsingProtocol``.
public enum NetworkError: Error, Equatable, Sendable {
    /// The endpoint's path or query items could not form a valid URL.
    case invalidURL
    /// An `.encodable` body failed to encode.
    case requestEncodingFailed
    /// The authorization provider threw (e.g. a required token is missing).
    case authorizationFailed
    /// An interceptor's `adapt` threw; the associated value describes the
    /// underlying error.
    case interceptorFailed(String)
    /// The response was not an `HTTPURLResponse`.
    case noResponse
    /// A URL-loading/transport error (no connectivity, timeout…); the
    /// associated value is its localized description.
    case transportFailure(String)
    /// The connection dropped while a streamed body was being received; the
    /// associated value is the underlying error's localized description.
    /// Thrown while iterating a stream, never by the call that opened it.
    case streamInterrupted(String)
    /// The response body could not be decoded into the requested type.
    case decodingFailure(String)
    /// Any `4xx` other than 401, 403 and 404.
    case clientError(statusCode: Int, message: String?)
    /// HTTP 401.
    case unauthorized(message: String?)
    /// HTTP 403.
    case forbidden(message: String?)
    /// HTTP 404.
    case notFound(message: String?)
    /// Any `5xx`.
    case serverError(statusCode: Int, message: String?)
    /// A status code outside `2xx–5xx`.
    case unexpectedStatusCode(Int, message: String?)
}

extension NetworkError: LocalizedError {

    /// User-facing text: the server-provided message when available, otherwise
    /// a generic description localized in English and Brazilian Portuguese.
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return Self.localized("error.invalidURL")
        case .requestEncodingFailed:
            return Self.localized("error.requestEncodingFailed")
        case .authorizationFailed:
            return Self.localized("error.authorizationFailed")
        case .interceptorFailed:
            // The associated value carries the underlying error for diagnostics;
            // users get the localized generic text, as with `decodingFailure`.
            return Self.localized("error.interceptorFailed")
        case .noResponse:
            return Self.localized("error.noResponse")
        case .transportFailure(let message),
             .streamInterrupted(let message):
            // Already-localized description coming from the underlying URL error.
            return message
        case .decodingFailure:
            return Self.localized("error.decodingFailure")
        case .clientError(_, let message),
             .unauthorized(let message),
             .forbidden(let message),
             .notFound(let message),
             .serverError(_, let message),
             .unexpectedStatusCode(_, let message):
            // Prefer the server-provided message; fall back to a localized default.
            return message ?? Self.localized("error.generic")
        }
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: .module, comment: "")
    }
}
