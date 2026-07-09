import Foundation
import Testing
@testable import Kuang

@Suite("HTTP Client Streaming", .tags(.networking, .httpClient, .streaming))
struct HTTPClientStreamingTests {

    // MARK: - Handshake & delivery

    @Test("A 2xx handshake delivers the body chunks in order, with authorization applied")
    func streamDeliversChunksInOrder() async throws {
        let session = StreamingSessionSpy()
        session.nextResult = .success(Script(chunks: [Data("first".utf8), Data("second".utf8)]))

        let sut = makeSUT(
            session: session,
            authorizationProvider: BearerTokenAuthorizationProvider { "token-xyz" }
        )

        var received: [Data] = []
        for try await chunk in try await sut.stream(endpoint: StubEndpoint(authorizationType: .bearerToken)) {
            received.append(chunk)
        }

        #expect(received == [Data("first".utf8), Data("second".utf8)])
        #expect(session.receivedRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token-xyz")
    }

    @Test("A non-2xx handshake throws the same NetworkError as the buffered path, with the parsed message")
    func non2xxHandshakeThrowsMappedError() async {
        let session = StreamingSessionSpy()
        session.nextResult = .success(Script(
            statusCode: 400,
            chunks: [Data(#"{"message":"bad request"}"#.utf8)]
        ))

        let sut = makeSUT(session: session)

        do {
            _ = try await sut.stream(endpoint: StubEndpoint())
            Issue.record("Expected stream to throw")
        } catch let error as NetworkError {
            #expect(error == .clientError(statusCode: 400, message: "bad request"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("The endpoint's timeout is applied to the outgoing request")
    func endpointTimeoutIsApplied() async throws {
        let session = StreamingSessionSpy()
        session.nextResult = .success(Script())

        let sut = makeSUT(session: session)

        for try await _ in try await sut.stream(endpoint: StubEndpoint(timeout: 90)) {}

        #expect(session.receivedRequests.first?.timeoutInterval == 90)
    }

    // MARK: - Retry semantics

    @Test("A failed handshake is retried when an interceptor grants it")
    func handshakeFailureIsRetried() async throws {
        let session = StreamingSessionSpy()
        session.results = [
            .success(Script(statusCode: 503)),
            .success(Script(chunks: [Data("ok".utf8)]))
        ]

        let sut = makeSUT(session: session, interceptors: [RetryInterceptor(maxRetryCount: 2, delay: 0)])

        var received: [Data] = []
        for try await chunk in try await sut.stream(endpoint: StubEndpoint()) {
            received.append(chunk)
        }

        #expect(received == [Data("ok".utf8)])
        #expect(session.receivedRequests.count == 2)
    }

    @Test("A mid-stream failure surfaces as streamInterrupted and is never retried")
    func midStreamFailureIsNotRetried() async throws {
        let session = StreamingSessionSpy()
        session.nextResult = .success(Script(
            chunks: [Data("partial".utf8)],
            streamError: URLError(.networkConnectionLost)
        ))

        let sut = makeSUT(session: session, interceptors: [RetryInterceptor(maxRetryCount: 3, delay: 0)])

        var received: [Data] = []
        do {
            for try await chunk in try await sut.stream(endpoint: StubEndpoint()) {
                received.append(chunk)
            }
            Issue.record("Expected iteration to throw")
        } catch let error as NetworkError {
            guard case .streamInterrupted = error else {
                Issue.record("Expected streamInterrupted, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(received == [Data("partial".utf8)])
        #expect(session.receivedRequests.count == 1)
    }

    @Test("The configuration's maxAttempts caps handshake retries")
    func maxAttemptsCapsHandshakeRetries() async {
        let session = StreamingSessionSpy()
        session.nextResult = .failure(URLError(.networkConnectionLost))

        let sut = makeSUT(
            session: session,
            maxAttempts: 3,
            interceptors: [AlwaysRetryStreamInterceptor()]
        )

        do {
            _ = try await sut.stream(endpoint: StubEndpoint())
            Issue.record("Expected stream to throw")
        } catch let error as NetworkError {
            guard case .transportFailure = error else {
                Issue.record("Expected transportFailure, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(session.receivedRequests.count == 3)
    }

    // MARK: - Cancellation

    @Test("Cancelling the consuming task terminates the underlying transport stream")
    func cancellationPropagatesToTransport() async throws {
        let session = StreamingSessionSpy()
        session.nextResult = .success(Script(chunks: [Data("a".utf8)], holdOpen: true))

        let sut = makeSUT(session: session)

        let consumer = Task {
            for try await _ in try await sut.stream(endpoint: StubEndpoint()) {}
        }

        // Let the handshake complete and the first chunk flow before cancelling.
        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()
        _ = try? await consumer.value

        var cancelled = false
        for _ in 0 ..< 50 where !cancelled {
            cancelled = session.terminationCount > 0
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(cancelled, "The transport stream was never terminated after cancellation")
    }

    // MARK: - Server-Sent Events

    @Test("streamEvents parses events split across chunk boundaries")
    func streamEventsParsesAcrossChunks() async throws {
        let session = StreamingSessionSpy()
        session.nextResult = .success(Script(chunks: [
            Data("data: hel".utf8),
            Data("lo\n\nevent: done\ndata: bye\n\n".utf8)
        ]))

        let sut = makeSUT(session: session)

        var events: [ServerSentEvent] = []
        for try await event in try await sut.streamEvents(endpoint: StubEndpoint()) {
            events.append(event)
        }

        #expect(events == [
            ServerSentEvent(data: "hello"),
            ServerSentEvent(event: "done", data: "bye")
        ])
    }

    @Test("streamEvents dispatches a trailing event when the server omits the final blank line")
    func streamEventsFlushesTrailingEvent() async throws {
        let session = StreamingSessionSpy()
        session.nextResult = .success(Script(chunks: [Data("data: tail".utf8)]))

        let sut = makeSUT(session: session)

        var events: [ServerSentEvent] = []
        for try await event in try await sut.streamEvents(endpoint: StubEndpoint()) {
            events.append(event)
        }

        #expect(events == [ServerSentEvent(data: "tail")])
    }

    @Test("The decoding variant decodes payloads and stops at the terminator sentinel")
    func decodingVariantStopsAtTerminator() async throws {
        let session = StreamingSessionSpy()
        session.nextResult = .success(Script(chunks: [Data("""
        data: {"value":"a"}

        data: {"value":"b"}

        data: [DONE]

        data: {"value":"never delivered"}

        """.utf8)]))

        let sut = makeSUT(session: session)

        var received: [ChunkDTO] = []
        for try await chunk in try await sut.streamEvents(endpoint: StubEndpoint(), decoding: ChunkDTO.self) {
            received.append(chunk)
        }

        #expect(received == [ChunkDTO(value: "a"), ChunkDTO(value: "b")])
    }

    @Test("An undecodable event payload ends the decoded stream with decodingFailure")
    func decodingVariantSurfacesDecodingFailure() async throws {
        let session = StreamingSessionSpy()
        session.nextResult = .success(Script(chunks: [Data("data: not-json\n\n".utf8)]))

        let sut = makeSUT(session: session)

        do {
            for try await _ in try await sut.streamEvents(endpoint: StubEndpoint(), decoding: ChunkDTO.self) {}
            Issue.record("Expected iteration to throw")
        } catch let error as NetworkError {
            guard case .decodingFailure = error else {
                Issue.record("Expected decodingFailure, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Logging

    @Test("Stream logs share the request ID and the closure summary counts bytes and events")
    func streamLogsShareRequestIDAndSummarize() async throws {
        let session = StreamingSessionSpy()
        let body = "data: one\n\ndata: two\n\n"
        session.nextResult = .success(Script(chunks: [Data(body.utf8)]))
        let logger = StreamingLoggerSpy()

        let sut = makeSUT(session: session, logger: logger)

        for try await _ in try await sut.streamEvents(endpoint: StubEndpoint()) {}

        let ids = Set(logger.requestContexts.map(\.requestID)
            + logger.openedContexts.map(\.requestID)
            + logger.closedContexts.map(\.requestID))
        #expect(ids.count == 1)
        #expect(logger.openedContexts.count == 1)

        let summary = try #require(logger.closedSummaries.first)
        #expect(summary.byteCount == body.utf8.count)
        #expect(summary.eventCount == 2)
        #expect(summary.duration >= 0)
        #expect(summary.error == nil)
    }

    @Test("A failed stream's closure summary carries the error")
    func failedStreamSummaryCarriesError() async throws {
        let session = StreamingSessionSpy()
        session.nextResult = .success(Script(streamError: URLError(.networkConnectionLost)))
        let logger = StreamingLoggerSpy()

        let sut = makeSUT(session: session, logger: logger)

        do {
            for try await _ in try await sut.stream(endpoint: StubEndpoint()) {}
        } catch {}

        let summary = try #require(logger.closedSummaries.first)
        guard case .streamInterrupted = try #require(summary.error) else {
            Issue.record("Expected streamInterrupted in the summary, got \(String(describing: summary.error))")
            return
        }
    }
}

// MARK: - Helpers

private extension HTTPClientStreamingTests {
    func makeSUT(
        session: StreamingSessionSpy,
        maxAttempts: Int = 10,
        authorizationProvider: AuthorizationProvidingProtocol = EmptyAuthorizationProvider(),
        logger: NetworkLoggingProtocol = DisabledNetworkLogger(),
        interceptors: [NetworkInterceptorProtocol] = []
    ) -> HTTPClient {
        HTTPClient(
            configuration: NetworkConfiguration(
                baseURL: URL(string: "http://localhost:3000")!,
                maxAttempts: maxAttempts
            ),
            streamingSession: session,
            authorizationProvider: authorizationProvider,
            logger: logger,
            interceptors: interceptors
        )
    }
}

// MARK: - Test doubles

private struct ChunkDTO: Decodable, Equatable, Sendable {
    let value: String
}

private struct StubEndpoint: EndpointProtocol {
    var path = "/stream"
    var method = HTTPMethod.get
    var authorizationType: AuthorizationType = .none
    var timeout: TimeInterval?
}

/// One scripted attempt: the response status and how its body behaves.
private struct Script {
    var statusCode = 200
    var chunks: [Data] = []
    /// Thrown after `chunks` are delivered, simulating a mid-stream drop.
    var streamError: Error?
    /// Leaves the stream unfinished so cancellation behavior can be observed.
    var holdOpen = false
}

private final class StreamingSessionSpy: HTTPStreamingSessionProtocol, @unchecked Sendable {
    /// Consumed in order when non-empty; otherwise `nextResult` is used.
    var results: [Result<Script, Error>] = []
    var nextResult: Result<Script, Error> = .success(Script())
    private(set) var receivedRequests: [URLRequest] = []
    /// Times a vended stream was terminated (finished, failed or cancelled).
    private(set) var terminationCount = 0

    func byteStream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        receivedRequests.append(request)
        let script = try (results.isEmpty ? nextResult : results.removeFirst()).get()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: script.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.terminationCount += 1
            }
            for chunk in script.chunks {
                continuation.yield(chunk)
            }
            guard !script.holdOpen else { return }
            if let error = script.streamError {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
        return (stream, response)
    }
}

private struct AlwaysRetryStreamInterceptor: NetworkInterceptorProtocol {
    func retry(_ endpoint: EndpointProtocol, dueTo error: NetworkError, attempt: Int) async -> RetryDecision {
        .retry
    }
}

private final class StreamingLoggerSpy: NetworkLoggingProtocol, @unchecked Sendable {
    private(set) var requestContexts: [NetworkLogContext] = []
    private(set) var openedContexts: [NetworkLogContext] = []
    private(set) var closedContexts: [NetworkLogContext] = []
    private(set) var closedSummaries: [StreamClosureSummary] = []

    func log(request: URLRequest, context: NetworkLogContext) {
        requestContexts.append(context)
    }

    func log(responseData: Data, response: HTTPURLResponse, duration: TimeInterval, context: NetworkLogContext) {}
    func log(error: Error, request: URLRequest?, context: NetworkLogContext) {}
    func log(retryDecision: RetryDecision, dueTo error: NetworkError, context: NetworkLogContext) {}

    func log(streamOpened response: HTTPURLResponse, duration: TimeInterval, context: NetworkLogContext) {
        openedContexts.append(context)
    }

    func log(streamClosed summary: StreamClosureSummary, context: NetworkLogContext) {
        closedContexts.append(context)
        closedSummaries.append(summary)
    }
}
