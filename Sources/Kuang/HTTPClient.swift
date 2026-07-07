import Foundation

/// Abstraction over `URLSession` so the client can be tested with a fake
/// session that never touches the network.
public protocol HTTPSessionProtocol: Sendable {
    /// Mirror of `URLSession.data(for:)`.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSessionProtocol {}

/// The client surface consumed by app code.
///
/// Depend on this protocol rather than on ``HTTPClient`` directly, so the
/// code making requests can be tested with a stub client.
public protocol NetworkClientProtocol: Sendable {
    /// Sends the request and decodes the response body into `T`.
    ///
    /// Throws `NetworkError` for any failure, or `CancellationError` if the
    /// surrounding task is cancelled.
    @discardableResult
    func request<T: Decodable>(endpoint: EndpointProtocol, responseType: T.Type) async throws -> T
    /// Sends the request and discards any response body. Use for endpoints
    /// that return no meaningful payload (e.g. `204 No Content`).
    ///
    /// Throws `NetworkError` for any failure, or `CancellationError` if the
    /// surrounding task is cancelled.
    func request(endpoint: EndpointProtocol) async throws
}

/// The package's `URLSession`-backed client.
///
/// Builds a `URLRequest` from an ``EndpointProtocol``, applies authorization
/// and interceptors, executes it, validates the status code and decodes the
/// response. Every failure surfaces as a ``NetworkError``; task cancellation
/// propagates as Swift's `CancellationError`.
public final class HTTPClient: NetworkClientProtocol, Sendable {

    private let configuration: NetworkConfiguration
    private let session: HTTPSessionProtocol
    private let authorizationProvider: AuthorizationProvidingProtocol
    private let logger: NetworkLoggingProtocol
    private let interceptors: [NetworkInterceptorProtocol]

    /// - Parameters:
    ///   - configuration: base URL, default headers, coders and retry cap.
    ///   - session: transport to use; `URLSession.shared` by default.
    ///   - authorizationProvider: turns each endpoint's ``AuthorizationType``
    ///     into headers. Defaults to ``EmptyAuthorizationProvider``, which
    ///     fails `.bearerToken` endpoints.
    ///   - logger: traffic observer; logging is disabled by default.
    ///   - interceptors: run in order on every request (see
    ///     ``NetworkInterceptorProtocol``).
    public init(
        configuration: NetworkConfiguration,
        session: HTTPSessionProtocol = URLSession.shared,
        authorizationProvider: AuthorizationProvidingProtocol = EmptyAuthorizationProvider(),
        logger: NetworkLoggingProtocol = DisabledNetworkLogger(),
        interceptors: [NetworkInterceptorProtocol] = []
    ) {
        self.configuration = configuration
        self.session = session
        self.authorizationProvider = authorizationProvider
        self.logger = logger
        self.interceptors = interceptors
    }

    public func request<T: Decodable>(endpoint: EndpointProtocol, responseType: T.Type) async throws -> T {
        let data = try await send(endpoint)
        return try decode(data, as: responseType)
    }

    public func request(endpoint: EndpointProtocol) async throws {
        _ = try await send(endpoint)
    }
}

private extension HTTPClient {

    func send(_ endpoint: EndpointProtocol) async throws -> Data {
        // Shared by every log entry of this call so its attempts can be
        // correlated among concurrent traffic.
        let requestID = NetworkLogContext.makeRequestID()
        var attempt = 0

        while true {
            try Task.checkCancellation()

            let context = NetworkLogContext(requestID: requestID, attempt: attempt + 1)
            // Kept outside the `do` so the error path can log the request that
            // actually failed; stays `nil` if the failure precedes building it.
            var request: URLRequest?

            do {
                let preparedRequest = try await prepareRequest(for: endpoint)
                request = preparedRequest
                logger.log(request: preparedRequest, context: context)
                return try await perform(preparedRequest, context: context)
            } catch let networkError as NetworkError {
                logger.log(error: networkError, request: request, context: context)

                // `attempt` is zero-based, so `attempt + 1` is the number of
                // attempts already made.
                guard attempt + 1 < configuration.maxAttempts else {
                    throw networkError
                }

                let decision = await retryDecision(for: endpoint, dueTo: networkError, attempt: attempt)
                switch decision {
                case .doNotRetry:
                    throw networkError
                case .retry:
                    logger.log(retryDecision: decision, dueTo: networkError, context: context)
                    attempt += 1
                case .retryAfter(let delay):
                    logger.log(retryDecision: decision, dueTo: networkError, context: context)
                    // Throws `CancellationError` if the task is cancelled while
                    // waiting, aborting the retry loop.
                    try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    attempt += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // An interceptor's `adapt` threw a non-`NetworkError`; keep the
                // public contract that this method only ever throws `NetworkError`
                // (or `CancellationError`).
                logger.log(error: error, request: request, context: context)
                throw NetworkError.interceptorFailed(error.localizedDescription)
            }
        }
    }

    func prepareRequest(for endpoint: EndpointProtocol) async throws -> URLRequest {
        var request = try buildRequest(from: endpoint)
        for interceptor in interceptors {
            request = try await interceptor.adapt(request, for: endpoint)
        }
        return request
    }

    func perform(_ request: URLRequest, context: NetworkLogContext) async throws -> Data {
        let start = DispatchTime.now()
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.noResponse
            }

            let duration = TimeInterval(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            logger.log(responseData: data, response: httpResponse, duration: duration, context: context)
            try validateStatusCode(of: httpResponse, data: data)

            return data
        } catch let networkError as NetworkError {
            throw networkError
        } catch {
            throw NetworkError.transportFailure(error.localizedDescription)
        }
    }

    func retryDecision(for endpoint: EndpointProtocol, dueTo error: NetworkError, attempt: Int) async -> RetryDecision {
        for interceptor in interceptors {
            let decision = await interceptor.retry(endpoint, dueTo: error, attempt: attempt)
            if decision != .doNotRetry {
                return decision
            }
        }
        return .doNotRetry
    }

    func buildRequest(from endpoint: EndpointProtocol) throws -> URLRequest {
        let url = try buildURL(for: endpoint)

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.allHTTPHeaderFields = configuration.defaultHeaders.merging(endpoint.headers) { _, new in
            new
        }

        do {
            let authorizationHeaders = try authorizationProvider.headers(for: endpoint.authorizationType)
            authorizationHeaders.forEach { key, value in
                request.setValue(value, forHTTPHeaderField: key)
            }
        } catch {
            throw NetworkError.authorizationFailed
        }

        switch endpoint.task {
        case .plain:
            break
        case .data(let data, let contentType):
            request.httpBody = data
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        case .encodable(let body):
            do {
                request.httpBody = try configuration.encoder.encode(AnyEncodable(body))
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            } catch {
                throw NetworkError.requestEncodingFailed
            }
        }

        return request
    }

    func buildURL(for endpoint: EndpointProtocol) throws -> URL {
        let normalizedPath = endpoint.path.hasPrefix("/") ? String(endpoint.path.dropFirst()) : endpoint.path
        let url = configuration.baseURL.appendingPathComponent(normalizedPath)

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }

        if !endpoint.queryItems.isEmpty {
            components.queryItems = endpoint.queryItems
        }

        guard let finalURL = components.url else {
            throw NetworkError.invalidURL
        }

        return finalURL
    }

    func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try configuration.decoder.decode(type, from: data)
        } catch {
            throw NetworkError.decodingFailure(error.localizedDescription)
        }
    }

    func validateStatusCode(of response: HTTPURLResponse, data: Data) throws {
        let message = configuration.errorMessageParser.message(from: data, response: response)

        switch response.statusCode {
        case 200 ... 299:
            return
        case 401:
            throw NetworkError.unauthorized(message: message)
        case 403:
            throw NetworkError.forbidden(message: message)
        case 404:
            throw NetworkError.notFound(message: message)
        case 400 ... 499:
            throw NetworkError.clientError(statusCode: response.statusCode, message: message)
        case 500 ... 599:
            throw NetworkError.serverError(statusCode: response.statusCode, message: message)
        default:
            throw NetworkError.unexpectedStatusCode(response.statusCode, message: message)
        }
    }
}
