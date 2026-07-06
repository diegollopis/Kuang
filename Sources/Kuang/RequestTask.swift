import Foundation

public enum RequestTask: Sendable {
    case plain
    case data(Data, contentType: String? = nil)
    case encodable(any Encodable & Sendable)
}
