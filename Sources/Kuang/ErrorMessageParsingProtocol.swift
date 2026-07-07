import Foundation

/// Extracts a user-facing message from an HTTP error response body.
///
/// The client consults the configuration's parser whenever a non-2xx response
/// arrives; the result is carried in the corresponding ``NetworkError`` case.
/// Returning `nil` makes `errorDescription` fall back to a localized generic
/// message. Provide your own implementation when your API uses an error
/// envelope the ``DefaultErrorMessageParser`` doesn't understand.
public protocol ErrorMessageParsingProtocol: Sendable {
    /// Returns the user-facing message carried by an error response, or `nil`
    /// to fall back to a localized generic message.
    func message(from data: Data, response: HTTPURLResponse) -> String?
}

/// Understands the common `{"message": …}` and `{"error": …}` JSON envelopes
/// and falls back to short plain-text bodies.
///
/// Bodies that are valid JSON without a known message key, look like markup
/// (e.g. an HTML error page from a proxy), or exceed `maxPlainTextLength`
/// yield `nil`, so users see a localized generic message instead of raw
/// server output.
public struct DefaultErrorMessageParser: ErrorMessageParsingProtocol {

    private let maxPlainTextLength: Int

    /// - Parameter maxPlainTextLength: plain-text bodies longer than this are
    ///   treated as not user-facing and yield `nil`.
    public init(maxPlainTextLength: Int = 300) {
        self.maxPlainTextLength = maxPlainTextLength
    }

    public func message(from data: Data, response: HTTPURLResponse) -> String? {
        guard !data.isEmpty else {
            return nil
        }

        if let json = try? JSONSerialization.jsonObject(with: data) {
            guard let object = json as? [String: Any] else {
                return nil
            }

            if let message = object["message"] as? String {
                return message
            }

            if let error = object["error"] as? String {
                return error
            }

            return nil
        }

        return plainText(from: data)
    }

    private func plainText(from data: Data) -> String? {
        guard
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty,
            !text.hasPrefix("<"),
            text.count <= maxPlainTextLength
        else {
            return nil
        }

        return text
    }
}
