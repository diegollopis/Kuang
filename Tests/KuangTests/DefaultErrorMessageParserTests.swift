import Foundation
import Testing
@testable import Kuang

@Suite("Default error message parser", .tags(.networking))
struct DefaultErrorMessageParserTests {

    private let sut = DefaultErrorMessageParser()

    @Test(
        "Known JSON envelopes and short plain text yield the server message",
        arguments: [
            (#"{"status":400,"message":"bad request"}"#, "bad request"),
            (#"{"message":"only message"}"#, "only message"),
            (#"{"error":"only error"}"#, "only error"),
            ("plain text body", "plain text body")
        ]
    )
    func extractsMessageFromKnownShapes(payload: String, expected: String) {
        #expect(sut.message(from: Data(payload.utf8), response: makeResponse()) == expected)
    }

    @Test(
        "Markup, unknown JSON and oversized bodies yield nil",
        arguments: [
            "<html><body><h1>502 Bad Gateway</h1></body></html>",
            #"{"code":42,"detail":"unknown envelope"}"#,
            #"["an","array"]"#,
            String(repeating: "x", count: 301),
            "",
            "   \n  "
        ]
    )
    func rejectsNonMessageBodies(payload: String) {
        #expect(sut.message(from: Data(payload.utf8), response: makeResponse()) == nil)
    }

    @Test("The plain-text length limit is configurable")
    func plainTextLimitIsConfigurable() {
        let permissive = DefaultErrorMessageParser(maxPlainTextLength: 1_000)
        let longText = String(repeating: "x", count: 500)

        #expect(permissive.message(from: Data(longText.utf8), response: makeResponse()) == longText)
    }

    private func makeResponse(_ statusCode: Int = 400) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://localhost:3000/secure")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
