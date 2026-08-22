import Foundation

public enum PairingError: Error, Equatable {
    case malformedCertificate
    case malformedResponse(String)
    case notPaired
    case pinMismatch
    case serverVerificationFailed
    case timedOut
    case httpStatus(Int)
    case transport(String)
    case notImplemented(String)
    /// Host refused /launch or /resume with a non-200 status; `message` is the host's own explanation.
    case launchRejected(code: Int, message: String)
}

extension PairingError: CustomStringConvertible {
    public var description: String { userMessage }
}

public extension PairingError {
    /// Canonical user-facing text — the single copy; every surface renders this directly.
    var userMessage: String {
        switch self {
        case .malformedCertificate: return "The PC returned an unreadable certificate."
        case let .malformedResponse(detail): return detail
        case .notPaired: return "The PC reported the pairing didn't complete. Try again."
        case .pinMismatch: return "That PIN didn't match. Double-check the digits and try again."
        case .serverVerificationFailed:
            return "Couldn't verify the PC's identity. If you reinstalled Sunshine/Apollo, re-pair."
        case .timedOut: return "Pairing timed out. Make sure you entered the PIN on the PC in time."
        case let .httpStatus(code): return "The PC rejected the request (HTTP \(code))."
        case let .transport(detail): return "Couldn't reach the PC: \(detail)"
        case let .notImplemented(detail): return "Unsupported pairing step: \(detail)"
        case let .launchRejected(_, message): return message
        }
    }
}
