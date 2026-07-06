import Foundation
import Testing
@testable import Kuang

@Suite("HTTP Client", .tags(.networking, .httpClient))
struct HTTPClientTests {

    // MARK: - Success & authorization

    @Test("When authorization requires a bearer token, the request includes it and decodes the response")
    func requestAddsBearerTokenAndDecodesSuccessResponse() async throws {
        let session = HTTPSessionSpy()
        session.nextResult = .success((try okData(), makeResponse()))

        let sut = HTTPClient(
            configuration: makeConfiguration(),
            session: session,
            authorizationProvider: BearerTokenAuthorizationProvider { "token-xyz" }
        )

        let response = try await sut.request(
            endpoint: StubEndpoint(authorizationType: .bearerToken),
            responseType: ResponseDTO.self
        )

        #expect(response.value == "ok")
        #expect(session.receivedRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token-xyz")
    }

    @Test("The no-body overload sends the request and ignores the response payload")
    func requestWithoutResponseTypeIgnoresBody() async throws {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(), makeResponse(204)))

        let sut = HTTPClient(configuration: makeConfiguration(), session: session)

        try await sut.request(endpoint: StubEndpoint())

        #expect(session.receivedRequests.count == 1)
    }

    // MARK: - Request body

    @Test("Encodable task encodes the body and defaults Content-Type to application/json")
    func requestEncodesBodyAndSetsJSONContentType() async throws {
        let session = HTTPSessionSpy()
        session.nextResult = .success((try okData(), makeResponse()))

        let sut = HTTPClient(configuration: makeConfiguration(), session: session)

        _ = try await sut.request(
            endpoint: StubEndpoint(method: .post, task: .encodable(RequestBody(name: "Ana"))),
            responseType: ResponseDTO.self
        )

        let sent = session.receivedRequests.first
        #expect(sent?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let decoded = try JSONDecoder().decode(RequestBody.self, from: sent?.httpBody ?? Data())
        #expect(decoded == RequestBody(name: "Ana"))
    }

    @Test("Data task sends the raw body and the provided content type")
    func requestSendsRawDataWithContentType() async throws {
        let session = HTTPSessionSpy()
        session.nextResult = .success((try okData(), makeResponse()))

        let sut = HTTPClient(configuration: makeConfiguration(), session: session)
        let payload = Data("<note/>".utf8)

        _ = try await sut.request(
            endpoint: StubEndpoint(method: .post, task: .data(payload, contentType: "application/xml")),
            responseType: ResponseDTO.self
        )

        let sent = session.receivedRequests.first
        #expect(sent?.httpBody == payload)
        #expect(sent?.value(forHTTPHeaderField: "Content-Type") == "application/xml")
    }

    // MARK: - Headers & URL

    @Test("Default and endpoint headers merge, with endpoint and auth taking precedence")
    func requestMergesHeaders() async throws {
        let session = HTTPSessionSpy()
        session.nextResult = .success((try okData(), makeResponse()))

        let configuration = NetworkConfiguration(
            baseURL: baseURL,
            defaultHeaders: ["X-App": "1", "X-Default": "d"]
        )
        let sut = HTTPClient(
            configuration: configuration,
            session: session,
            authorizationProvider: BearerTokenAuthorizationProvider { "tkn" }
        )

        _ = try await sut.request(
            endpoint: StubEndpoint(headers: ["X-App": "2"], authorizationType: .bearerToken),
            responseType: ResponseDTO.self
        )

        let sent = session.receivedRequests.first
        #expect(sent?.value(forHTTPHeaderField: "X-App") == "2")
        #expect(sent?.value(forHTTPHeaderField: "X-Default") == "d")
        #expect(sent?.value(forHTTPHeaderField: "Authorization") == "Bearer tkn")
    }

    @Test(
        "When query items are provided, the request URL includes them",
        arguments: [
            "page=2",
            "page=2&filter=cardiology"
        ]
    )
    func requestBuildsURLWithQueryItems(query: String) async throws {
        let session = HTTPSessionSpy()
        session.nextResult = .success((try okData(), makeResponse()))

        let sut = HTTPClient(configuration: makeConfiguration(), session: session)

        let queryItems = query
            .split(separator: "&")
            .map { pair -> URLQueryItem in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return URLQueryItem(name: parts[0], value: parts.count > 1 ? parts[1] : nil)
            }

        _ = try await sut.request(
            endpoint: StubEndpoint(queryItems: queryItems),
            responseType: ResponseDTO.self
        )

        #expect(session.receivedRequests.first?.url?.absoluteString == "http://localhost:3000/secure?\(query)")
    }

    // MARK: - Error mapping

    @Test("When the server responds with an error status, it maps to the expected service error", arguments: [401, 403, 404, 422, 503, 302])
    func requestMapsResponseStatusCodesIntoNetworkErrors(statusCode: Int) async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(), makeResponse(statusCode)))

        let sut = HTTPClient(configuration: makeConfiguration(), session: session)

        do {
            _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            #expect(error == expectedError(for: statusCode))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(
        "Server error messages are extracted from common payload shapes",
        arguments: [
            (#"{"status":400,"message":"bad request"}"#, "bad request"),
            (#"{"message":"only message"}"#, "only message"),
            (#"{"error":"only error"}"#, "only error"),
            ("plain text body", "plain text body")
        ]
    )
    func requestExtractsServerMessage(payload: String, expected: String) async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(payload.utf8), makeResponse(400)))

        let sut = HTTPClient(configuration: makeConfiguration(), session: session)

        do {
            _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            #expect(error == .clientError(statusCode: 400, message: expected))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A custom error message parser replaces the default one")
    func customErrorMessageParserIsConsulted() async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(#"{"detail":"weird envelope"}"#.utf8), makeResponse(400)))

        let configuration = NetworkConfiguration(
            baseURL: baseURL,
            errorMessageParser: StaticMessageParser(staticMessage: "parsed by custom parser")
        )
        let sut = HTTPClient(configuration: configuration, session: session)

        do {
            _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            #expect(error == .clientError(statusCode: 400, message: "parsed by custom parser"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("An HTML error page never becomes the user-facing message")
    func htmlErrorPageYieldsNilMessage() async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data("<html><h1>502 Bad Gateway</h1></html>".utf8), makeResponse(502)))

        let sut = HTTPClient(configuration: makeConfiguration(), session: session)

        do {
            _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            #expect(error == .serverError(statusCode: 502, message: nil))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A transport-level failure maps to transportFailure")
    func requestMapsTransportFailure() async {
        let session = HTTPSessionSpy()
        session.nextResult = .failure(URLError(.notConnectedToInternet))

        let sut = HTTPClient(configuration: makeConfiguration(), session: session)

        do {
            _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            guard case .transportFailure = error else {
                Issue.record("Expected transportFailure, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("An undecodable payload maps to decodingFailure")
    func requestMapsDecodingFailure() async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data("not-json".utf8), makeResponse()))

        let sut = HTTPClient(configuration: makeConfiguration(), session: session)

        do {
            _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            guard case .decodingFailure = error else {
                Issue.record("Expected decodingFailure, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("When the authorization provider throws, it maps to authorizationFailed")
    func requestMapsAuthorizationFailure() async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(), makeResponse()))

        let sut = HTTPClient(
            configuration: makeConfiguration(),
            session: session,
            authorizationProvider: FailingAuthorizationProvider()
        )

        do {
            _ = try await sut.request(endpoint: StubEndpoint(authorizationType: .bearerToken), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            #expect(error == .authorizationFailed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("With the default policy, a missing bearer token fails before the request is sent")
    func missingBearerTokenFailsFast() async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(), makeResponse()))

        let sut = HTTPClient(
            configuration: makeConfiguration(),
            session: session,
            authorizationProvider: BearerTokenAuthorizationProvider { nil }
        )

        do {
            _ = try await sut.request(endpoint: StubEndpoint(authorizationType: .bearerToken), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            #expect(error == .authorizationFailed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(session.receivedRequests.isEmpty)
    }

    @Test("With the omitHeader policy, a missing bearer token sends the request without the header")
    func omitHeaderPolicySendsRequestWithoutAuthorization() async throws {
        let session = HTTPSessionSpy()
        session.nextResult = .success((try okData(), makeResponse()))

        let sut = HTTPClient(
            configuration: makeConfiguration(),
            session: session,
            authorizationProvider: BearerTokenAuthorizationProvider(missingTokenPolicy: .omitHeader) { nil }
        )

        _ = try await sut.request(endpoint: StubEndpoint(authorizationType: .bearerToken), responseType: ResponseDTO.self)

        #expect(session.receivedRequests.count == 1)
        #expect(session.receivedRequests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A bearerToken endpoint with the default (empty) provider is a wiring error")
    func bearerEndpointWithoutTokenProviderFails() async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(), makeResponse()))

        let sut = HTTPClient(configuration: makeConfiguration(), session: session)

        do {
            _ = try await sut.request(endpoint: StubEndpoint(authorizationType: .bearerToken), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            #expect(error == .authorizationFailed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(session.receivedRequests.isEmpty)
    }

    // MARK: - Interceptors

    @Test("An interceptor's adapt can mutate the outgoing request")
    func interceptorAdaptsRequest() async throws {
        let session = HTTPSessionSpy()
        session.nextResult = .success((try okData(), makeResponse()))

        let sut = HTTPClient(
            configuration: makeConfiguration(),
            session: session,
            interceptors: [HeaderInjectingInterceptor(field: "X-Trace", value: "abc")]
        )

        _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)

        #expect(session.receivedRequests.first?.value(forHTTPHeaderField: "X-Trace") == "abc")
    }

    @Test("RetryInterceptor retries transient failures and then succeeds")
    func retriesTransientFailureThenSucceeds() async throws {
        let session = HTTPSessionSpy()
        session.results = [
            .success((Data(), makeResponse(503))),
            .success((Data(), makeResponse(503))),
            .success((try okData(), makeResponse()))
        ]

        let sut = HTTPClient(
            configuration: makeConfiguration(),
            session: session,
            interceptors: [RetryInterceptor(maxRetryCount: 3, delay: 0)]
        )

        let response = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)

        #expect(response.value == "ok")
        #expect(session.receivedRequests.count == 3)
    }

    @Test("RetryInterceptor stops after maxRetryCount and throws the last error")
    func retryExhaustionThrowsLastError() async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(), makeResponse(503)))

        let sut = HTTPClient(
            configuration: makeConfiguration(),
            session: session,
            interceptors: [RetryInterceptor(maxRetryCount: 2, delay: 0)]
        )

        do {
            _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            #expect(error == .serverError(statusCode: 503, message: nil))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // First attempt + 2 retries.
        #expect(session.receivedRequests.count == 3)
    }

    @Test("When an interceptor's adapt throws, it maps to interceptorFailed")
    func adaptFailureMapsToInterceptorFailed() async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(), makeResponse()))

        let sut = HTTPClient(
            configuration: makeConfiguration(),
            session: session,
            interceptors: [ThrowingAdaptInterceptor()]
        )

        do {
            _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            guard case .interceptorFailed = error else {
                Issue.record("Expected interceptorFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(session.receivedRequests.isEmpty)
    }

    @Test("The configuration's maxAttempts caps retries even if an interceptor always asks to retry")
    func maxAttemptsCapsARunawayInterceptor() async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(), makeResponse(503)))

        let sut = HTTPClient(
            configuration: makeConfiguration(maxAttempts: 3),
            session: session,
            interceptors: [AlwaysRetryInterceptor()]
        )

        do {
            _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            #expect(error == .serverError(statusCode: 503, message: nil))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(session.receivedRequests.count == 3)
    }

    @Test("Cancelling the task during a retry delay stops retrying and throws CancellationError")
    func cancellationDuringRetryDelayStopsRetrying() async throws {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(), makeResponse(503)))

        let sut = HTTPClient(
            configuration: makeConfiguration(),
            session: session,
            interceptors: [RetryInterceptor(maxRetryCount: 5, delay: 60)]
        )

        let task = Task {
            try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
        }

        // Let the first attempt fail and the client enter the 60s retry delay.
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the request to be cancelled")
        } catch is CancellationError {
            // Expected: the delay was interrupted instead of running out.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(session.receivedRequests.count == 1)
    }

    @Test("RetryInterceptor does not retry non-transient failures")
    func doesNotRetryClientErrors() async {
        let session = HTTPSessionSpy()
        session.nextResult = .success((Data(), makeResponse(404)))

        let sut = HTTPClient(
            configuration: makeConfiguration(),
            session: session,
            interceptors: [RetryInterceptor(maxRetryCount: 3, delay: 0)]
        )

        do {
            _ = try await sut.request(endpoint: StubEndpoint(), responseType: ResponseDTO.self)
            Issue.record("Expected request to throw")
        } catch let error as NetworkError {
            #expect(error == .notFound(message: nil))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(session.receivedRequests.count == 1)
    }
}

// MARK: - Helpers

private extension HTTPClientTests {
    var baseURL: URL { URL(string: "http://localhost:3000")! }

    func makeConfiguration(maxAttempts: Int = 10) -> NetworkConfiguration {
        NetworkConfiguration(baseURL: baseURL, maxAttempts: maxAttempts)
    }

    func makeResponse(_ statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://localhost:3000/secure")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func okData() throws -> Data {
        try JSONEncoder().encode(ResponseDTO(value: "ok"))
    }

    func expectedError(for statusCode: Int) -> NetworkError {
        switch statusCode {
        case 401:
            return .unauthorized(message: nil)
        case 403:
            return .forbidden(message: nil)
        case 404:
            return .notFound(message: nil)
        case 400 ... 499:
            return .clientError(statusCode: statusCode, message: nil)
        case 500 ... 599:
            return .serverError(statusCode: statusCode, message: nil)
        default:
            return .unexpectedStatusCode(statusCode, message: nil)
        }
    }
}

// MARK: - Test doubles

private struct ResponseDTO: Codable, Equatable {
    let value: String
}

private struct RequestBody: Codable, Equatable, Sendable {
    let name: String
}

private struct StubEndpoint: EndpointProtocol {
    var path = "/secure"
    var method = HTTPMethod.get
    var task = RequestTask.plain
    var headers: [String: String] = [:]
    var queryItems: [URLQueryItem] = []
    var authorizationType: AuthorizationType = .none
}

private struct FailingAuthorizationProvider: AuthorizationProvidingProtocol {
    enum Failure: Error { case unavailable }

    func headers(for authorizationType: AuthorizationType) throws -> [String: String] {
        throw Failure.unavailable
    }
}

private struct HeaderInjectingInterceptor: NetworkInterceptorProtocol {
    let field: String
    let value: String

    func adapt(_ request: URLRequest, for endpoint: EndpointProtocol) async throws -> URLRequest {
        var request = request
        request.setValue(value, forHTTPHeaderField: field)
        return request
    }
}

private struct StaticMessageParser: ErrorMessageParsingProtocol {
    let staticMessage: String

    func message(from data: Data, response: HTTPURLResponse) -> String? {
        staticMessage
    }
}

private struct ThrowingAdaptInterceptor: NetworkInterceptorProtocol {
    enum Failure: Error { case adaptBroke }

    func adapt(_ request: URLRequest, for endpoint: EndpointProtocol) async throws -> URLRequest {
        throw Failure.adaptBroke
    }
}

private struct AlwaysRetryInterceptor: NetworkInterceptorProtocol {
    func retry(_ endpoint: EndpointProtocol, dueTo error: NetworkError, attempt: Int) async -> RetryDecision {
        .retry
    }
}

private final class HTTPSessionSpy: HTTPSessionProtocol, @unchecked Sendable {
    /// Consumed in order when non-empty; otherwise `nextResult` is returned.
    var results: [Result<(Data, URLResponse), Error>] = []
    var nextResult: Result<(Data, URLResponse), Error> = .success((Data(), URLResponse()))
    private(set) var receivedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        receivedRequests.append(request)
        if !results.isEmpty {
            return try results.removeFirst().get()
        }
        return try nextResult.get()
    }
}
