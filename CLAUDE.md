# CLAUDE.md

Guidance for coding agents working on this repository.

## Project

Kuang is a protocol-oriented networking layer for Swift, distributed as an SPM
package. Swift tools 5.10; platforms iOS 15+ / macOS 12+. No dependencies.

## Commands

- `swift build` — build the package.
- `swift test` — run the suite (Swift Testing, not XCTest).

## Architecture

- Every seam is a `*Protocol` with a sensible default, injected through
  `HTTPClient.init` (session, streaming session, authorization, logger,
  interceptors). App code is expected to depend on `NetworkClientProtocol` /
  `StreamingClientProtocol`, not on `HTTPClient`.
- Every failure surfaces as the single `NetworkError` type; task cancellation
  is the one exception and propagates as `CancellationError`.
- The buffered request path lives in `HTTPClient.swift`; the streaming path in
  `HTTPClient+Streaming.swift`. Both share request building, interceptors,
  status validation and the retry loop — but streams are only retried during
  the handshake, never after the first chunk reaches the consumer.
- Interceptor semantics: `adapt` runs once per attempt; on failure the first
  interceptor returning something other than `.doNotRetry` wins;
  `NetworkConfiguration.maxAttempts` is a hard cap regardless.

## Conventions

- The public API is fully documented with DocC comments, in English.
- User-facing error strings are localized in English and Brazilian Portuguese
  (`Sources/Kuang/Resources/*.lproj/Localizable.strings`); every new
  `NetworkError` case needs an `errorDescription` mapping.
- Tests use `@Suite`/`@Test` with descriptive sentence names and tags from
  `TestTags.swift`. Test doubles are hand-written spies/stubs, declared
  `private` in the test file that uses them.
- Public API changes should stay additive when possible (defaulted protocol
  requirements, defaulted init parameters) so existing conformances keep
  compiling.

## Verification

To verify changes end-to-end (beyond `swift test`), follow the recipe in
`.claude/skills/verify/SKILL.md`: consume the package from a scratch
executable against a local server.
