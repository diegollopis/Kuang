import Foundation

/// The outcome an interceptor returns when asked whether a failed request
/// should be retried.
public enum RetryDecision: Sendable, Equatable {
    /// Do not retry; the error is propagated to the caller.
    case doNotRetry
    /// Retry immediately.
    case retry
    /// Retry after waiting `TimeInterval` seconds.
    case retryAfter(TimeInterval)
}

/// A piece of behavior that can run across every request handled by ``HTTPClient``.
///
/// Interceptors enable cross-cutting concerns (auth refresh, retry, tracing,
/// signing) without modifying the client. They run in the order they are
/// supplied to the client:
/// - ``adapt(_:for:)`` is invoked for **every attempt**, so an interceptor that
///   refreshes a token can inject the new value before each retry.
/// - ``retry(_:dueTo:attempt:)`` is consulted after a failure; the first
///   interceptor returning a decision other than ``RetryDecision/doNotRetry``
///   wins.
public protocol NetworkInterceptorProtocol: Sendable {
    /// Mutates the outgoing request before it is sent. Called once per attempt.
    func adapt(_ request: URLRequest, for endpoint: EndpointProtocol) async throws -> URLRequest
    /// Decides whether a failed request should be retried.
    /// - Parameter attempt: zero-based index of the attempt that just failed.
    func retry(_ endpoint: EndpointProtocol, dueTo error: NetworkError, attempt: Int) async -> RetryDecision
}

public extension NetworkInterceptorProtocol {
    func adapt(_ request: URLRequest, for endpoint: EndpointProtocol) async throws -> URLRequest { request }
    func retry(_ endpoint: EndpointProtocol, dueTo error: NetworkError, attempt: Int) async -> RetryDecision { .doNotRetry }
}

/// A ready-to-use interceptor that retries transient failures a bounded number
/// of times with a fixed delay.
public struct RetryInterceptor: NetworkInterceptorProtocol {

    /// Maximum number of retries, not counting the first attempt.
    public let maxRetryCount: Int
    /// Seconds to wait before each retry; `0` retries immediately.
    public let delay: TimeInterval
    private let isRetryable: @Sendable (NetworkError) -> Bool

    /// - Parameters:
    ///   - maxRetryCount: maximum number of retries (not counting the first attempt).
    ///   - delay: seconds to wait before each retry. `0` retries immediately.
    ///   - isRetryable: predicate deciding which errors are worth retrying.
    public init(
        maxRetryCount: Int = 2,
        delay: TimeInterval = 0.5,
        isRetryable: @escaping @Sendable (NetworkError) -> Bool = RetryInterceptor.isTransient
    ) {
        self.maxRetryCount = maxRetryCount
        self.delay = delay
        self.isRetryable = isRetryable
    }

    public func retry(_ endpoint: EndpointProtocol, dueTo error: NetworkError, attempt: Int) async -> RetryDecision {
        guard attempt < maxRetryCount, isRetryable(error) else {
            return .doNotRetry
        }
        return delay > 0 ? .retryAfter(delay) : .retry
    }

    /// Treats network transport problems and 5xx responses as retryable.
    public static let isTransient: @Sendable (NetworkError) -> Bool = { error in
        switch error {
        case .transportFailure, .noResponse, .serverError:
            return true
        default:
            return false
        }
    }
}
