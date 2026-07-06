import Foundation

public enum AuthorizationType: Sendable {
    case none
    case bearerToken
    case custom(String)
}

public protocol AuthorizationProvidingProtocol: Sendable {
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
