import Foundation

/// Incremental Server-Sent Events parser.
///
/// Feed it body chunks in arrival order via ``parse(_:)``; it buffers partial
/// frames internally and returns only complete events. Handles the framing
/// details of the WHATWG EventSource spec: `\n`, `\r\n` and `\r` line endings,
/// events split across chunk boundaries, multi-line `data:` fields, comment
/// lines, and unknown fields. Multi-byte UTF-8 sequences split across chunks
/// are safe because splitting only happens at line terminators, which are
/// single bytes that never appear inside a multi-byte UTF-8 character.
struct ServerSentEventParser {

    private var buffer = Data()
    private var dataLines: [String] = []
    private var eventType: String?
    private var lastEventID: String?
    private var retry: TimeInterval?

    /// Consumes the next chunk and returns the events it completed, in order.
    mutating func parse(_ chunk: Data) -> [ServerSentEvent] {
        buffer.append(chunk)

        var events: [ServerSentEvent] = []
        while let line = nextLine() {
            if let event = process(line) {
                events.append(event)
            }
        }
        return events
    }

    /// Call once at end of stream. Terminates a trailing line that never got
    /// its line ending and returns the event it completes, for servers that
    /// close the connection without a final blank line.
    mutating func flush() -> ServerSentEvent? {
        if !buffer.isEmpty {
            buffer.append(0x0A)
            while let line = nextLine() {
                if let event = process(line) {
                    return event
                }
            }
        }
        return dispatch()
    }
}

private extension ServerSentEventParser {

    /// Extracts the next complete line from the buffer, or `nil` when none is
    /// terminated yet.
    mutating func nextLine() -> String? {
        guard let terminator = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
            return nil
        }
        // A trailing `\r` may be the first half of a `\r\n` pair whose `\n`
        // hasn't arrived yet; wait for the next chunk to decide.
        if buffer[terminator] == 0x0D, terminator == buffer.index(before: buffer.endIndex) {
            return nil
        }

        let line = String(decoding: buffer[buffer.startIndex ..< terminator], as: UTF8.self)
        var lineEnd = buffer.index(after: terminator)
        if buffer[terminator] == 0x0D, buffer[lineEnd] == 0x0A {
            lineEnd = buffer.index(after: lineEnd)
        }
        buffer.removeSubrange(buffer.startIndex ..< lineEnd)
        return line
    }

    /// Accumulates one line into the pending event; a blank line dispatches it.
    mutating func process(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            // Comment line (e.g. keep-alives like ": ping").
            return nil
        }

        let name: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            name = line[line.startIndex ..< colon]
            value = line[line.index(after: colon)...]
            // The spec strips a single leading space from the value.
            if value.hasPrefix(" ") {
                value = value.dropFirst()
            }
        } else {
            name = line[...]
            value = ""
        }

        switch name {
        case "data":
            dataLines.append(String(value))
        case "event":
            eventType = String(value)
        case "id" where !value.contains("\0"):
            lastEventID = String(value)
        case "retry":
            // Digits-only per the spec; anything else is ignored.
            if let milliseconds = UInt64(value) {
                retry = TimeInterval(milliseconds) / 1_000
            }
        default:
            // Unknown fields are ignored per the spec.
            break
        }
        return nil
    }

    /// Emits the pending event, or `nil` when no `data:` line accumulated —
    /// the spec drops data-less events. `lastEventID` deliberately survives:
    /// the identifier is sticky across events.
    mutating func dispatch() -> ServerSentEvent? {
        defer {
            dataLines.removeAll()
            eventType = nil
            retry = nil
        }

        guard !dataLines.isEmpty else {
            return nil
        }
        return ServerSentEvent(
            event: eventType,
            data: dataLines.joined(separator: "\n"),
            id: lastEventID,
            retry: retry
        )
    }
}
