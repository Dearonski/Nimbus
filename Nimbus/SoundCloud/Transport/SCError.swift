import Foundation

enum SCError: Error {
    case notAuthenticated
    case clientIDNotFound
    case http(Int)
    case badResponse
    /// The request answered 200 but the body no longer fits the model — SoundCloud changed the
    /// schema. Carries what to go look at instead of leaving a bare `DecodingError`.
    case decoding(endpoint: String, field: String, detail: String)
}
