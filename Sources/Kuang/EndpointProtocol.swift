import Foundation

public protocol EndpointProtocol: Sendable {
    var path: String { get }
    var method: HTTPMethod { get }
    var task: RequestTask { get }
    var headers: [String: String] { get }
    var queryItems: [URLQueryItem] { get }
    var authorizationType: AuthorizationType { get }
}

public extension EndpointProtocol {
    var task: RequestTask { .plain }
    var headers: [String: String] { [:] }
    var queryItems: [URLQueryItem] { [] }
    var authorizationType: AuthorizationType { .none }
}
