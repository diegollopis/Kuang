import Foundation
import Testing
@testable import Kuang

@Suite("Server-Sent Event Parser", .tags(.networking, .streaming))
struct ServerSentEventParserTests {

    // MARK: - Basic framing

    @Test("A single event in a single chunk is parsed")
    func parsesSingleEvent() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("data: hello\n\n".utf8))

        #expect(events == [ServerSentEvent(data: "hello")])
    }

    @Test("Multiple events in one chunk are parsed in order")
    func parsesMultipleEventsInOneChunk() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("data: one\n\ndata: two\n\n".utf8))

        #expect(events == [ServerSentEvent(data: "one"), ServerSentEvent(data: "two")])
    }

    @Test("An event split across chunks mid-line is reassembled")
    func reassemblesEventSplitAcrossChunks() {
        var parser = ServerSentEventParser()

        var events = parser.parse(Data("da".utf8))
        #expect(events.isEmpty)
        events += parser.parse(Data("ta: hel".utf8))
        #expect(events.isEmpty)
        events += parser.parse(Data("lo\n\n".utf8))

        #expect(events == [ServerSentEvent(data: "hello")])
    }

    @Test("Multiple data lines are joined with a newline")
    func joinsMultiLineData() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("data: first\ndata: second\n\n".utf8))

        #expect(events == [ServerSentEvent(data: "first\nsecond")])
    }

    // MARK: - Line endings

    @Test("CRLF line endings are honoured")
    func handlesCRLFLineEndings() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("data: x\r\n\r\n".utf8))

        #expect(events == [ServerSentEvent(data: "x")])
    }

    @Test("Lone CR line endings are honoured, holding a chunk-final CR until the next byte decides it")
    func handlesLoneCRLineEndings() {
        var parser = ServerSentEventParser()

        // The trailing CR could still be the first half of a CRLF pair, so
        // the event completes only when the next chunk (or EOF) resolves it.
        var events = parser.parse(Data("data: x\r\r".utf8))
        #expect(events.isEmpty)

        events += parser.parse(Data("data: y\r\r".utf8))
        #expect(events == [ServerSentEvent(data: "x")])
        #expect(parser.flush() == ServerSentEvent(data: "y"))
    }

    @Test("A CRLF pair split across two chunks yields a single line break")
    func handlesCRLFSplitAcrossChunks() {
        var parser = ServerSentEventParser()

        var events = parser.parse(Data("data: x\r".utf8))
        #expect(events.isEmpty)
        events += parser.parse(Data("\n\r\n".utf8))

        #expect(events == [ServerSentEvent(data: "x")])
    }

    @Test("A multi-byte UTF-8 character split across chunks is decoded intact")
    func handlesUTF8SplitAcrossChunks() {
        var parser = ServerSentEventParser()
        let payload = Array("data: olá\n\n".utf8)
        // "á" is two bytes; cut between them.
        let cut = payload.count - 3

        var events = parser.parse(Data(payload[..<cut]))
        #expect(events.isEmpty)
        events += parser.parse(Data(payload[cut...]))

        #expect(events == [ServerSentEvent(data: "olá")])
    }

    // MARK: - Fields

    @Test("event, id and retry fields are captured")
    func capturesAllFields() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("event: message\nid: 42\nretry: 3000\ndata: x\n\n".utf8))

        #expect(events == [ServerSentEvent(event: "message", data: "x", id: "42", retry: 3.0)])
    }

    @Test("The event identifier is sticky across subsequent events")
    func eventIDIsSticky() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("id: 7\ndata: a\n\ndata: b\n\n".utf8))

        #expect(events.map(\.id) == ["7", "7"])
    }

    @Test("A value's single leading space is stripped, further spaces are kept")
    func stripsOneLeadingSpace() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("data:  padded\n\ndata:tight\n\n".utf8))

        #expect(events.map(\.data) == [" padded", "tight"])
    }

    @Test("A field line without a colon is a field with an empty value")
    func fieldWithoutColonHasEmptyValue() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("data\n\n".utf8))

        #expect(events == [ServerSentEvent(data: "")])
    }

    @Test("A non-numeric retry value is ignored")
    func ignoresNonNumericRetry() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("retry: soon\ndata: x\n\n".utf8))

        #expect(events == [ServerSentEvent(data: "x")])
    }

    // MARK: - Skipped content

    @Test("Comment lines are ignored")
    func ignoresComments() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data(": keep-alive\n\ndata: x\n\n".utf8))

        #expect(events == [ServerSentEvent(data: "x")])
    }

    @Test("An event without a data field is not dispatched")
    func dropsDataLessEvents() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("event: ping\n\n".utf8))

        #expect(events.isEmpty)
    }

    // MARK: - End of stream

    @Test("flush dispatches a trailing event that never got its blank line")
    func flushDispatchesTrailingEvent() {
        var parser = ServerSentEventParser()

        let events = parser.parse(Data("data: tail".utf8))
        #expect(events.isEmpty)

        #expect(parser.flush() == ServerSentEvent(data: "tail"))
    }

    @Test("flush returns nil when nothing is pending")
    func flushWithNothingPendingReturnsNil() {
        var parser = ServerSentEventParser()

        _ = parser.parse(Data("data: complete\n\n".utf8))

        #expect(parser.flush() == nil)
    }
}
