import Foundation

/// One complete Server-Sent Event, as framed by the WHATWG EventSource spec.
///
/// Yielded by ``StreamingClientProtocol/streamEvents(endpoint:)``. Most APIs
/// carry a JSON payload in ``data``; use ``decode(_:using:)`` to turn it into
/// a model.
public struct ServerSentEvent: Sendable, Equatable {
    /// Value of the `event:` field; `nil` when the server omitted it.
    public let event: String?
    /// The event payload: all `data:` lines of the event, joined with `\n`.
    public let data: String
    /// The last `id:` value seen on the stream. Per the spec the identifier
    /// is sticky: it persists across subsequent events until the server sends
    /// a new one.
    public let id: String?
    /// Reconnection delay carried by a `retry:` field on this event, converted
    /// from the wire's milliseconds to seconds. `nil` when the event carried none.
    public let retry: TimeInterval?

    /// - Parameters:
    ///   - event: value of the `event:` field, when present.
    ///   - data: the event payload.
    ///   - id: the stream's current event identifier, when known.
    ///   - retry: server-suggested reconnection delay, in seconds.
    public init(event: String? = nil, data: String, id: String? = nil, retry: TimeInterval? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }

    /// Decodes ``data`` into `T`.
    ///
    /// Throws ``NetworkError/decodingFailure(_:)`` when the payload is not
    /// valid JSON for `T` — including sentinel payloads such as OpenAI's
    /// `[DONE]`, so filter those out before decoding (or use
    /// ``StreamingClientProtocol/streamEvents(endpoint:decoding:decoder:terminator:)``,
    /// which does it for you).
    public func decode<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        do {
            return try decoder.decode(type, from: Data(data.utf8))
        } catch {
            throw NetworkError.decodingFailure(error.localizedDescription)
        }
    }
}
