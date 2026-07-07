<p align="center">
  <img src="Assets/kuang-banner.png" alt="Kuang — network layer · swift package" width="720">
</p>

<p align="center">
  <a href="https://github.com/diegollopis/Kuang/actions/workflows/ci.yml"><img src="https://github.com/diegollopis/Kuang/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.10+">
  <img src="https://img.shields.io/badge/Platforms-iOS%2015%2B%20%7C%20macOS%2012%2B-0969da" alt="Platforms: iOS 15+ | macOS 12+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-lightgrey" alt="License: MIT"></a>
</p>

A small, protocol-oriented networking layer for Swift. It turns type-safe endpoint
definitions into `URLRequest`s, executes them with `async/await`, decodes the
response, and maps transport and HTTP errors into a single `NetworkError` type.

- **Endpoint-driven** — describe an API as an `enum`; the client builds the request.
- **Dependency-injected** — session, authorization, logging and interceptors are all
  pluggable, so everything is testable without hitting the network.
- **Concurrency-safe** — the public surface is `Sendable`; the client is an
  `actor`-friendly `final class`.
- **Localized errors** — `NetworkError` conforms to `LocalizedError` (English and
  Brazilian Portuguese bundled).

## Requirements

| | |
|---|---|
| Swift tools | 5.10 |
| Platforms | iOS 15+, macOS 12+ |

## Installation

### Swift Package Manager

Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/diegollopis/Kuang.git", from: "1.0.0")
]
```

Then list the product in your target:

```swift
.target(
    name: "MyFeature",
    dependencies: ["Kuang"]
)
```

### Xcode

**File ▸ Add Package Dependencies…**, paste the repository URL, and add
`Kuang` to your app target.

> Consuming it from a local checkout instead? Point the dependency at the folder:
> `.package(path: "../Kuang")`.

## Quick start

### 1. Define an endpoint

Conform an `enum` to `Endpoint`. Only `path` and `method` are required — `task`,
`headers`, `queryItems` and `authorizationType` all have sensible defaults.

```swift
import Kuang

enum SpecialistEndpoint: Endpoint {
    case all
    case create(NewSpecialist)

    var path: String {
        switch self {
        case .all, .create: "/specialists"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .all:    .get
        case .create: .post
        }
    }

    var task: RequestTask {
        switch self {
        case .all:                .plain
        case .create(let body):   .encodable(body)
        }
    }

    var authorizationType: AuthorizationType {
        switch self {
        case .all:    .none
        case .create: .bearerToken
        }
    }
}
```

### 2. Build a client

```swift
let configuration = NetworkConfiguration(
    baseURL: URL(string: "https://api.example.com")!
)

let client = HTTPClient(configuration: configuration)
```

### 3. Make a request

There are two overloads:

```swift
// Decodes the response body into the requested type.
let specialists = try await client.request(
    endpoint: SpecialistEndpoint.all,
    responseType: [Specialist].self
)

// No meaningful body (e.g. 204 No Content) — nothing to decode.
try await client.request(endpoint: SpecialistEndpoint.create(newSpecialist))
```

The typed overload returns a **non-optional** value: a successful call always yields a
decoded model, and the absence of a body is expressed by the no-body overload rather
than a `nil` result. The typed overload is also `@discardableResult`, so you can ignore
the value when you only care that the call succeeded.

## Configuration

`NetworkConfiguration` is immutable and shared across requests.

```swift
let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601

let configuration = NetworkConfiguration(
    baseURL: URL(string: "https://api.example.com")!,
    defaultHeaders: ["Accept": "application/json"],
    encoder: encoder,
    decoder: decoder
)
```

`defaultHeaders` are applied to every request. Headers declared on an endpoint, and
authorization headers, take precedence when keys collide.

## Request bodies

`RequestTask` controls the body that is sent:

```swift
// No body.
.plain

// An Encodable model — encoded with the configuration's JSONEncoder.
// Content-Type defaults to "application/json".
.encodable(CreateAppointment(date: date, specialistId: id))

// Raw bytes with an explicit content type.
.data(xmlData, contentType: "application/xml")
```

## Authorization

Set `authorizationType` per endpoint; an `AuthorizationProviding` turns it into headers.

```swift
public enum AuthorizationType {
    case none
    case bearerToken
    case custom(String)   // verbatim Authorization header value
}
```

### Bearer tokens

`BearerTokenAuthorizationProvider` reads the token lazily on each request, so a token
refreshed mid-session is always picked up. The closure is `@Sendable` and may throw.

```swift
let client = HTTPClient(
    configuration: configuration,
    authorizationProvider: BearerTokenAuthorizationProvider {
        try tokenStore.currentToken()   // returns String?
    }
)
```

Endpoints declared `.bearerToken` send `Authorization: Bearer <token>`; pass a custom
header field if your API differs:

```swift
BearerTokenAuthorizationProvider(headerField: "X-Auth-Token") {
    try tokenStore.currentToken()
}
```

A `nil` or empty token **fails the request before it leaves the device**, surfacing
`NetworkError.authorizationFailed`. Opt into the lenient behavior — sending the
request without the header and letting the server decide — with the
`missingTokenPolicy` parameter:

```swift
BearerTokenAuthorizationProvider(missingTokenPolicy: .omitHeader) {
    try tokenStore.currentToken()
}
```

If you don't supply a provider, the client uses `EmptyAuthorizationProvider`, which
honours `.custom(_:)` values and fails `.bearerToken` endpoints — demanding a token
with no token-capable provider configured is a wiring error.

### Custom schemes

```swift
var authorizationType: AuthorizationType {
    .custom("ApiKey \(apiKey)")   // sent as the Authorization header, as-is
}
```

## Logging

Pass any `NetworkLoggingProtocol` to observe traffic. Two implementations ship with the
package:

```swift
// Verbose output for requests, responses, errors and retries, built on os.Logger.
let client = HTTPClient(configuration: configuration, logger: ConsoleNetworkLogger())

// The default — logs nothing.
let client = HTTPClient(configuration: configuration, logger: DisabledNetworkLogger())
```

Every log entry carries a `NetworkLogContext` — a short `requestID` shared by all
entries of one call plus a 1-based `attempt` number — so interleaved concurrent
requests (and their retries) can be correlated. Response entries also report the
attempt's duration.

`ConsoleNetworkLogger` tags each entry `[requestID #attempt]`, logs responses with
status ≥ 400 at the `error` level, and includes the elapsed time next to the status
code. It redacts the `Authorization` header by default (add more via
`redactedHeaders:`) and logs request/response bodies with `.private` privacy — visible
while a debugger is attached, hidden in production device logs. Bodies longer than
`maxBodyLength` characters (default 10 000) are truncated, and non-UTF-8 bodies are
summarized by their byte count:

```swift
ConsoleNetworkLogger(
    subsystem: "com.example.MyApp",   // defaults to the app's bundle identifier
    redactedHeaders: ["Authorization", "X-Api-Key"],
    maxBodyLength: 4_000
)
```

Implement the protocol yourself for custom sinks:

```swift
struct AnalyticsNetworkLogger: NetworkLoggingProtocol {
    func log(request: URLRequest, context: NetworkLogContext) { /* ... */ }
    func log(responseData: Data, response: HTTPURLResponse, duration: TimeInterval, context: NetworkLogContext) { /* ... */ }
    func log(error: Error, request: URLRequest?, context: NetworkLogContext) { /* ... */ }
    func log(retryDecision: RetryDecision, dueTo error: NetworkError, context: NetworkLogContext) { /* ... */ }
}
```

## Interceptors & retries

A `NetworkInterceptor` runs cross-cutting behavior across every request without
touching the client:

- `adapt(_:for:)` mutates the outgoing request — called **once per attempt**, so it can
  inject a freshly refreshed token before each retry.
- `retry(_:dueTo:attempt:)` decides whether a failed request should be retried. The
  first interceptor that returns something other than `.doNotRetry` wins.

```swift
struct TracingInterceptor: NetworkInterceptor {
    func adapt(_ request: URLRequest, for endpoint: Endpoint) async throws -> URLRequest {
        var request = request
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }
}
```

### Built-in retry

`RetryInterceptor` retries transient failures (network errors and `5xx` by default) a
bounded number of times:

```swift
let client = HTTPClient(
    configuration: configuration,
    interceptors: [
        RetryInterceptor(maxRetryCount: 2, delay: 0.5)
    ]
)
```

Customize what counts as retryable:

```swift
RetryInterceptor(maxRetryCount: 3, delay: 1.0) { error in
    if case .serverError = error { return true }
    return false
}
```

Whatever interceptors decide, the client never exceeds
`NetworkConfiguration.maxAttempts` total attempts per request (default `10`) — a
safety net against a misbehaving interceptor retrying forever. Cancelling the
surrounding task interrupts a pending retry delay and throws `CancellationError`.

## Error handling

Every failure is surfaced as a `NetworkError` (task cancellation is the one
exception: it propagates as Swift's `CancellationError`):

```swift
do {
    let specialists = try await client.request(
        endpoint: SpecialistEndpoint.all,
        responseType: [Specialist].self
    )
} catch let error as NetworkError {
    switch error {
    case .unauthorized:
        // refresh credentials / sign the user out
    case .notFound(let message):
        print(message ?? "Not found")
    case .serverError(let statusCode, _):
        print("Server failed with \(statusCode)")
    default:
        print(error.localizedDescription)   // localized, user-facing
    }
}
```

`NetworkError` cases:

| Case | When |
|---|---|
| `invalidURL` | The endpoint path/query could not form a valid URL |
| `requestEncodingFailed` | An `.encodable` body failed to encode |
| `authorizationFailed` | The authorization provider threw |
| `interceptorFailed(String)` | An interceptor's `adapt` threw |
| `noResponse` | The response was not an `HTTPURLResponse` |
| `transportFailure(String)` | A URL-loading/transport error |
| `decodingFailure(String)` | The response body could not be decoded |
| `unauthorized` / `forbidden` / `notFound` | `401` / `403` / `404` |
| `clientError(statusCode:message:)` | Other `4xx` |
| `serverError(statusCode:message:)` | `5xx` |
| `unexpectedStatusCode(_:message:)` | Anything outside `2xx–5xx` |

For HTTP errors, the configuration's `ErrorMessageParsing` extracts a server message
and exposes it through `localizedDescription`. The `DefaultErrorMessageParser`
understands the common shapes — `{"message": …}`, `{"error": …}`, or a short plain-text
body — and deliberately yields `nil` for markup (HTML error pages from proxies), JSON
without a known message key, and oversized bodies, so raw server output never reaches
users; they get a localized generic message instead. Plug in your own parser for other
envelopes:

```swift
struct ProblemDetailsParser: ErrorMessageParsing {
    func message(from data: Data, response: HTTPURLResponse) -> String? {
        // e.g. RFC 7807: {"title": …, "detail": …}
    }
}

NetworkConfiguration(baseURL: url, errorMessageParser: ProblemDetailsParser())
```

Error strings are localized in English and Brazilian Portuguese.

## Testing

Inject a fake session to test without the network. Conform to `HTTPSessionProtocol`:

```swift
final class StubSession: HTTPSessionProtocol, @unchecked Sendable {
    var result: Result<(Data, URLResponse), Error>

    init(_ result: Result<(Data, URLResponse), Error>) { self.result = result }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try result.get()
    }
}

let response = HTTPURLResponse(
    url: URL(string: "https://api.example.com/specialists")!,
    statusCode: 200, httpVersion: nil, headerFields: nil
)!

let client = HTTPClient(
    configuration: configuration,
    session: StubSession(.success((jsonData, response)))
)
```

The package's own suite (`swift test`) shows the full range: authorization, header
merging, query items, body encoding, status-code mapping, retries and interceptors.

## License

See [LICENSE](LICENSE).
