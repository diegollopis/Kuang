import Foundation

/// ``HTTPClient``'s streaming support.
///
/// The handshake — building the request, running interceptors, opening the
/// connection and validating the status code — reuses the same machinery and
/// retry policy as `request(endpoint:)`. Retrying stops the moment the stream
/// is handed to the caller: a failure after that surfaces from the iteration
/// as ``NetworkError/streamInterrupted(_:)`` and is never retried, since the
/// consumer may already have acted on earlier chunks.
extension HTTPClient: StreamingClientProtocol {

    public func stream(endpoint: EndpointProtocol) async throws -> AsyncThrowingStream<Data, Error> {
        let handshake = try await open(endpoint)

        return AsyncThrowingStream { continuation in
            let task = Task { [logger] in
                var byteCount = 0
                do {
                    for try await chunk in handshake.chunks {
                        byteCount += chunk.count
                        continuation.yield(chunk)
                    }
                    logger.log(streamClosed: handshake.summary(byteCount: byteCount), context: handshake.context)
                    continuation.finish()
                } catch is CancellationError {
                    logger.log(streamClosed: handshake.summary(byteCount: byteCount), context: handshake.context)
                    continuation.finish(throwing: CancellationError())
                } catch {
                    let failure = NetworkError.streamInterrupted(error.localizedDescription)
                    logger.log(streamClosed: handshake.summary(byteCount: byteCount, error: failure), context: handshake.context)
                    continuation.finish(throwing: failure)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func streamEvents(endpoint: EndpointProtocol) async throws -> AsyncThrowingStream<ServerSentEvent, Error> {
        let handshake = try await open(endpoint)

        return AsyncThrowingStream { continuation in
            let task = Task { [logger] in
                var parser = ServerSentEventParser()
                var byteCount = 0
                var eventCount = 0
                do {
                    for try await chunk in handshake.chunks {
                        byteCount += chunk.count
                        for event in parser.parse(chunk) {
                            eventCount += 1
                            continuation.yield(event)
                        }
                    }
                    if let trailing = parser.flush() {
                        eventCount += 1
                        continuation.yield(trailing)
                    }
                    logger.log(streamClosed: handshake.summary(byteCount: byteCount, eventCount: eventCount), context: handshake.context)
                    continuation.finish()
                } catch is CancellationError {
                    logger.log(streamClosed: handshake.summary(byteCount: byteCount, eventCount: eventCount), context: handshake.context)
                    continuation.finish(throwing: CancellationError())
                } catch {
                    let failure = NetworkError.streamInterrupted(error.localizedDescription)
                    logger.log(streamClosed: handshake.summary(byteCount: byteCount, eventCount: eventCount, error: failure), context: handshake.context)
                    continuation.finish(throwing: failure)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// A successfully opened streamed response: headers validated, body pending.
private struct StreamHandshake {
    let chunks: AsyncThrowingStream<Data, Error>
    let context: NetworkLogContext
    let start: DispatchTime

    func summary(byteCount: Int, eventCount: Int? = nil, error: NetworkError? = nil) -> StreamClosureSummary {
        StreamClosureSummary(
            byteCount: byteCount,
            eventCount: eventCount,
            duration: HTTPClient.elapsedSeconds(since: start),
            error: error
        )
    }
}

private extension HTTPClient {

    /// Caps how much of a non-2xx response body is read for error-message
    /// parsing before the connection is dropped.
    static let maxErrorBodyBytes = 64 * 1_024

    /// The handshake: same retry loop as the buffered `send`, ending when a
    /// validated stream is obtained instead of a complete body.
    func open(_ endpoint: EndpointProtocol) async throws -> StreamHandshake {
        let requestID = NetworkLogContext.makeRequestID()
        var attempt = 0

        while true {
            try Task.checkCancellation()

            let context = NetworkLogContext(requestID: requestID, attempt: attempt + 1)
            var request: URLRequest?

            do {
                let preparedRequest = try await prepareRequest(for: endpoint)
                request = preparedRequest
                logger.log(request: preparedRequest, context: context)
                return try await connect(preparedRequest, context: context)
            } catch let networkError as NetworkError {
                logger.log(error: networkError, request: request, context: context)
                try await waitForGrantedRetry(for: endpoint, dueTo: networkError, attempt: &attempt, context: context)
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

    func connect(_ request: URLRequest, context: NetworkLogContext) async throws -> StreamHandshake {
        let start = DispatchTime.now()
        do {
            let (chunks, response) = try await streamingSession.byteStream(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.noResponse
            }

            let duration = Self.elapsedSeconds(since: start)
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                // A non-2xx body is an error envelope, not a stream: drain it
                // (bounded) so the configured parser can extract the message,
                // then fail through the same mapping as the buffered path.
                let body = await Self.drain(chunks, limit: Self.maxErrorBodyBytes)
                logger.log(responseData: body, response: httpResponse, duration: duration, context: context)
                try validateStatusCode(of: httpResponse, data: body)
                // `validateStatusCode` always throws for a non-2xx status;
                // this is an unreachable safety net.
                throw NetworkError.unexpectedStatusCode(httpResponse.statusCode, message: nil)
            }

            logger.log(streamOpened: httpResponse, duration: duration, context: context)
            return StreamHandshake(chunks: chunks, context: context, start: start)
        } catch let networkError as NetworkError {
            throw networkError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.transportFailure(error.localizedDescription)
        }
    }

    static func drain(_ chunks: AsyncThrowingStream<Data, Error>, limit: Int) async -> Data {
        var body = Data()
        do {
            for try await chunk in chunks {
                body.append(chunk)
                if body.count >= limit {
                    break
                }
            }
        } catch {
            // The status code already determines the failure; a transport
            // error while draining the error body only costs the parsed
            // message.
        }
        return body.count > limit ? body.prefix(limit) : body
    }
}
