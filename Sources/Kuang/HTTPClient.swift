import Foundation

public protocol HTTPSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSessionProtocol {}

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

public final class HTTPClient: NetworkClientProtocol, Sendable {

    private let configuration: NetworkConfiguration
    private let session: HTTPSessionProtocol
    private let authorizationProvider: AuthorizationProvidingProtocol
    private let logger: NetworkLoggingProtocol
    private let interceptors: [NetworkInterceptorProtocol]

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
        let data = try await send(endpoint) // busca os dados
        return try decode(data, as: responseType) // tenta decodificar o json de response na struct tipada informada no responseType
    }

    public func request(endpoint: EndpointProtocol) async throws {
        _ = try await send(endpoint)
    }
}

private extension HTTPClient {

    func send(_ endpoint: EndpointProtocol) async throws -> Data {
        var attempt = 0

        while true {
            try Task.checkCancellation()

            do {
                let request = try await prepareRequest(for: endpoint)
                logger.log(request: request)
                return try await perform(request)
            } catch let networkError as NetworkError {
                logger.log(error: networkError, request: nil)

                // `attempt` is zero-based, so `attempt + 1` is the number of
                // attempts already made.
                guard attempt + 1 < configuration.maxAttempts else {
                    throw networkError
                }

                switch await retryDecision(for: endpoint, dueTo: networkError, attempt: attempt) {
                case .doNotRetry:
                    throw networkError
                case .retry:
                    attempt += 1
                case .retryAfter(let delay):
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
                logger.log(error: error, request: nil)
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

    func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.noResponse
            }

            logger.log(responseData: data, response: httpResponse)
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
