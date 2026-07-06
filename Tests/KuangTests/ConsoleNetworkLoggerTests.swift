import Foundation
import Testing
@testable import Kuang

@Suite("Console network logger", .tags(.networking))
struct ConsoleNetworkLoggerTests {

    @Test("Sensitive headers are redacted case-insensitively; others pass through")
    func redactsSensitiveHeaders() {
        let sut = ConsoleNetworkLogger(redactedHeaders: ["Authorization", "X-Api-Key"])

        let sanitized = sut.sanitized([
            "authorization": "Bearer super-secret",
            "X-API-KEY": "key-123",
            "Accept": "application/json"
        ])

        #expect(sanitized["authorization"] == "<redacted>")
        #expect(sanitized["X-API-KEY"] == "<redacted>")
        #expect(sanitized["Accept"] == "application/json")
    }

    @Test("Authorization is redacted by default")
    func redactsAuthorizationByDefault() {
        let sut = ConsoleNetworkLogger()

        let sanitized = sut.sanitized(["Authorization": "Bearer super-secret"])

        #expect(sanitized["Authorization"] == "<redacted>")
    }

    // MARK: - Body description

    @Test("A missing or empty body yields nil so the BODY section is omitted")
    func describesEmptyBody() {
        let sut = ConsoleNetworkLogger()

        #expect(sut.bodyDescription(from: nil) == nil)
        #expect(sut.bodyDescription(from: Data()) == nil)
    }

    @Test("A JSON body is pretty-printed")
    func prettyPrintsJSONBody() {
        let sut = ConsoleNetworkLogger()

        let description = sut.bodyDescription(from: Data(#"{"name":"Ana"}"#.utf8))

        #expect(description == """
        {
          "name" : "Ana"
        }
        """)
    }

    @Test("A non-JSON UTF-8 body is logged as-is")
    func passesThroughPlainTextBody() {
        let sut = ConsoleNetworkLogger()

        #expect(sut.bodyDescription(from: Data("plain text".utf8)) == "plain text")
    }

    @Test("A binary body is summarized by its size instead of dumped")
    func summarizesBinaryBody() {
        let sut = ConsoleNetworkLogger()
        let binary = Data([0xFF, 0xD8, 0xFF, 0xE0])

        #expect(sut.bodyDescription(from: binary) == "<binary body: 4 bytes>")
    }

    @Test("A body longer than maxBodyLength is truncated with its total size")
    func truncatesLongBody() {
        let sut = ConsoleNetworkLogger(maxBodyLength: 10)
        let payload = Data(#"{"value":"0123456789ABCDEF"}"#.utf8)

        let description = sut.bodyDescription(from: payload)

        #expect(description == "{\"value\":\"\n… truncated (\(payload.count) bytes total)")
    }
}
