import Foundation

/// Abstraction over `URLSession.bytes(for:)` so streaming can be tested with
/// a fake session that never touches the network.
public protocol HTTPStreamingSessionProtocol: Sendable {
    /// Sends the request and returns as soon as the response headers arrive.
    ///
    /// The body follows as a stream of chunks that finishes when the server
    /// closes the connection, or throws when the transfer drops midway.
    func byteStream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse)
}

extension URLSession: HTTPStreamingSessionProtocol {
    /// Adapts `URLSession.bytes(for:)` into chunks.
    ///
    /// Bytes are grouped into a chunk that flushes on every line feed or once
    /// it reaches 1 KiB, whichever comes first — tuned for line-delimited
    /// streams (SSE, NDJSON), where it yields each line the moment it is
    /// complete. Supply your own conformance for transports with different
    /// buffering needs.
    public func byteStream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        let (bytes, response) = try await self.bytes(for: request)

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var chunk = Data()
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 1_024 {
                            continuation.yield(chunk)
                            chunk = Data()
                        }
                    }
                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    // Deliver what already arrived before surfacing the error,
                    // so consumers don't lose the tail of the transfer.
                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return (stream, response)
    }
}
