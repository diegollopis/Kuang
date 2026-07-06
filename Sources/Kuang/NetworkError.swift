import Foundation

public enum NetworkError: Error, Equatable, Sendable {
    case invalidURL
    case requestEncodingFailed
    case authorizationFailed
    case interceptorFailed(String)
    case noResponse
    case transportFailure(String)
    case decodingFailure(String)
    case clientError(statusCode: Int, message: String?)
    case unauthorized(message: String?)
    case forbidden(message: String?)
    case notFound(message: String?)
    case serverError(statusCode: Int, message: String?)
    case unexpectedStatusCode(Int, message: String?)
}

extension NetworkError: LocalizedError {

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
        case .transportFailure(let message):
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
