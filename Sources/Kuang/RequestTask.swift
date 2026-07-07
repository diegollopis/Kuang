import Foundation

/// The body an endpoint sends.
public enum RequestTask: Sendable {
    /// No body.
    case plain
    /// Raw bytes, optionally setting the `Content-Type` header.
    case data(Data, contentType: String? = nil)
    /// A model encoded with the configuration's `JSONEncoder`; `Content-Type`
    /// defaults to `application/json` when not set elsewhere.
    case encodable(any Encodable & Sendable)
}
