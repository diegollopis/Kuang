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
}
