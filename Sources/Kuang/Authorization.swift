import Foundation

/// How a request is authorized, declared per endpoint.
public enum AuthorizationType: Sendable {
    /// No authorization header.
    case none
    /// `Authorization: Bearer <token>`, with the token supplied by the
    /// client's ``BearerTokenAuthorizationProvider``.
    case bearerToken
    /// A verbatim `Authorization` header value, e.g. `"ApiKey abc123"`.
    case custom(String)
}

/// Turns an endpoint's ``AuthorizationType`` into concrete headers.
public protocol AuthorizationProvidingProtocol: Sendable {
    /// Returns the headers to set for `authorizationType`. Any thrown error
    /// fails the request as ``NetworkError/authorizationFailed``.
    func headers(for authorizationType: AuthorizationType) throws -> [String: String]
}

/// The client's default provider. It honours `.custom(_:)` values verbatim and
/// **fails** for `.bearerToken` — an endpoint demanding a token while no
/// token-capable provider is configured is a wiring error, and failing fast
/// beats a confusing server-side 401.
public struct EmptyAuthorizationProvider: AuthorizationProvidingProtocol {

    /// Thrown when an endpoint declares `.bearerToken` but the client was not
    /// given a token-capable provider. Surfaces as `NetworkError.authorizationFailed`.
    public struct MissingProviderError: Error {
        public init() {}
    }

    public init() {}

    public func headers(for authorizationType: AuthorizationType) throws -> [String: String] {
        switch authorizationType {
        case .none:
            return [:]
        case .bearerToken:
            throw MissingProviderError()
        case .custom(let value):
            return ["Authorization": value]
        }
    }
}

/// Sends `Authorization: Bearer <token>`, fetching the token lazily on each
/// request so a value refreshed mid-session is always picked up.
public struct BearerTokenAuthorizationProvider: AuthorizationProvidingProtocol {

    /// What to do when an endpoint requires `.bearerToken` but the token
    /// provider returns `nil` or an empty string.
    public enum MissingTokenPolicy: Sendable {
        /// Fail the request before it leaves the device (default). Surfaces as
        /// `NetworkError.authorizationFailed`.
        case fail
        /// Send the request without an Authorization header and let the server
        /// decide (the pre-1.0 behavior).
        case omitHeader
    }

    /// Thrown under ``MissingTokenPolicy/fail`` when no token is available.
    public struct MissingTokenError: Error {
        public init() {}
    }

    private let tokenProvider: @Sendable () throws -> String?
    private let headerField: String
    private let missingTokenPolicy: MissingTokenPolicy

    /// - Parameters:
    ///   - headerField: header that carries the token; `"Authorization"` by default.
    ///   - missingTokenPolicy: what to do when the provider yields no token.
    ///   - tokenProvider: closure returning the current token; called on every
    ///     request, so it always sees the freshest value. May throw.
    public init(
        headerField: String = "Authorization",
        missingTokenPolicy: MissingTokenPolicy = .fail,
        tokenProvider: @escaping @Sendable () throws -> String?
    ) {
        self.headerField = headerField
        self.missingTokenPolicy = missingTokenPolicy
        self.tokenProvider = tokenProvider
    }

    public func headers(for authorizationType: AuthorizationType) throws -> [String: String] {
        switch authorizationType {
        case .none:
            return [:]
        case .bearerToken:
            guard let token = try tokenProvider(), !token.isEmpty else {
                switch missingTokenPolicy {
                case .fail:
                    throw MissingTokenError()
                case .omitHeader:
                    return [:]
                }
            }
            return [headerField: "Bearer \(token)"]
        case .custom(let value):
            return [headerField: value]
        }
    }
}
