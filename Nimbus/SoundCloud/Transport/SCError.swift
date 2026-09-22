import Foundation
import os

enum SCError: Error {
    case notAuthenticated
    case clientIDNotFound
    case http(Int)
    case badResponse
    /// The request answered 200 but the body no longer fits the model — SoundCloud changed the
    /// schema. Carries what to go look at instead of leaving a bare `DecodingError`.
    case decoding(endpoint: String, field: String, detail: String)
}

private nonisolated let failureLog = Logger(subsystem: "io.github.dearonski.Nimbus", category: "failure")

extension Error {
    /// The sentence a screen shows; the raw error goes to the log, where a report picks it up.
    nonisolated func surfaced() -> String {
        // A cancelled request is the screen moving on, not a failure worth a line in a report.
        if (self as? URLError)?.code != .cancelled {
            failureLog.error("\(logLine, privacy: .public)")
        }
        return userMessage
    }

    nonisolated var userMessage: String {
        switch self {
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                "You're offline. Check your connection and try again."
            case .timedOut:
                "SoundCloud took too long to answer. Try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed:
                "Couldn't reach SoundCloud. Check your connection and try again."
            default:
                "The connection failed (\(error.code.rawValue)). Try again."
            }
        case let error as SCError:
            switch error {
            case .notAuthenticated, .http(401):
                "You're signed out. Sign in again to continue."
            case .http(403):
                "SoundCloud refused this request. If you're on a VPN, try turning it off."
            case .http(404):
                "This isn't on SoundCloud any more."
            case .http(429):
                "Too many requests. Wait a moment and try again."
            case .http(let code) where code >= 500:
                "SoundCloud is having trouble (\(code)). Try again in a moment."
            case .http(let code):
                "SoundCloud answered with an error (\(code))."
            case .clientIDNotFound:
                "Couldn't set up a connection to SoundCloud. Try again in a moment."
            case .badResponse:
                "SoundCloud sent an answer Nimbus couldn't read."
            case .decoding:
                "SoundCloud changed something Nimbus relies on. Help → Report an Issue… gets it fixed."
            }
        default:
            localizedDescription
        }
    }

    // A URLError prints its failing URL, and that carries the client_id.
    private nonisolated var logLine: String {
        guard let error = self as? URLError else { return "\(self)" }
        let url = error.failingURL.map { "\($0.host() ?? "")\($0.path())" } ?? "-"
        return "URLError \(error.code.rawValue) \(url)"
    }
}
