import Foundation

/// The streaming surface consumed by app code, for endpoints whose response
/// arrives progressively — Server-Sent Events from LLM APIs, NDJSON feeds,
/// long downloads.
///
/// Depend on this protocol rather than on ``HTTPClient`` directly, so code
/// consuming streams can be tested with a stub client.
///
/// Both methods split failures into two phases. Building the request and
/// validating the response status happen before the stream is returned, so
/// those failures are thrown by the call itself — and interceptors may retry
/// them, exactly as in `request(endpoint:)`. Once the stream is returned no
/// retry ever happens: a dropped connection surfaces while iterating, as
/// ``NetworkError/streamInterrupted(_:)``, because retrying midway would
/// replay chunks the consumer already handled.
public protocol StreamingClientProtocol: Sendable {
    /// Opens the connection, validates the HTTP status and returns the raw
    /// body chunks as they arrive.
    ///
    /// Throws `NetworkError` when the request cannot be built or the server
    /// answers with a non-2xx status; `CancellationError` if the surrounding
    /// task is cancelled. Cancelling the task that iterates the stream closes
    /// the connection.
    func stream(endpoint: EndpointProtocol) async throws -> AsyncThrowingStream<Data, Error>

    /// Same as ``stream(endpoint:)``, but parses the body as Server-Sent
    /// Events and yields one element per complete event.
    ///
    /// Comment lines (keep-alives) and events without a `data:` field are
    /// filtered out, per the SSE spec.
    func streamEvents(endpoint: EndpointProtocol) async throws -> AsyncThrowingStream<ServerSentEvent, Error>
}

public extension StreamingClientProtocol {
    /// Streams Server-Sent Events with each event's `data` payload decoded
    /// into `T`, for APIs that put one JSON document per event — the shape of
    /// every major LLM streaming API.
    ///
    /// - Parameters:
    ///   - endpoint: the endpoint to stream from.
    ///   - type: the model each event's payload is decoded into.
    ///   - decoder: decodes the payloads. A plain `JSONDecoder` by default.
    ///   - terminator: an event whose `data` equals this string ends the
    ///     stream without being decoded. Defaults to `"[DONE]"`, the OpenAI
    ///     sentinel; pass `nil` when the API has none (e.g. the Anthropic API,
    ///     which signals completion with a regular event instead).
    ///
    /// An event that fails to decode ends the stream by throwing
    /// ``NetworkError/decodingFailure(_:)`` from the iteration.
    func streamEvents<T: Decodable & Sendable>(
        endpoint: EndpointProtocol,
        decoding type: T.Type,
        decoder: JSONDecoder = JSONDecoder(),
        terminator: String? = "[DONE]"
    ) async throws -> AsyncThrowingStream<T, Error> {
        let events = try await streamEvents(endpoint: endpoint)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if let terminator, event.data == terminator {
                            break
                        }
                        continuation.yield(try event.decode(type, using: decoder))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
