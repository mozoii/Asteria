import Foundation
import Observation
import AsteriaKit

/// Renders one `PairingSession` attempt: holds the progress for the UI, restarts on retry.
/// All pairing logic — handshake, deadline, error text, persistence — lives in the package.
@MainActor
@Observable
final class PairingCoordinator {
    private(set) var phase: PairingProgress = .preparing

    /// Fingerprint of the identity that paired, once `.paired`.
    var pairedFingerprint: ClientFingerprint? {
        if case let .paired(fingerprint) = phase { return fingerprint }
        return nil
    }
    let host: HostRecord
    let deviceName: String
    let pinTimeoutSeconds: Double = PairingClient.defaultTimeoutSeconds

    private let identities: ClientIdentityVault
    private let onPaired: @MainActor (HostRecord) async -> Void

    init(host: HostRecord,
         deviceName: String = "Asteria",
         identities: ClientIdentityVault = .appKeychain,
         onPaired: @escaping @MainActor (HostRecord) async -> Void) {
        self.host = host
        self.deviceName = deviceName
        self.identities = identities
        self.onPaired = onPaired
    }

    /// Run one pairing attempt (each call starts a fresh attempt with a fresh identity).
    func start() async {
        let onPaired = self.onPaired
        let session = PairingSession(
            host: host,
            identities: identities,
            onPaired: { updated in await onPaired(updated) },
            configuration: PairingSessionConfiguration(
                deviceName: deviceName, pinTimeoutSeconds: pinTimeoutSeconds)
        )
        for await progress in session.run() {
            phase = progress
        }
    }

    #if DEBUG
    static func preview(host: HostRecord, phase: PairingProgress) -> PairingCoordinator {
        let coordinator = PairingCoordinator(host: host, onPaired: { _ in })
        coordinator.phase = phase
        return coordinator
    }
    #endif
}
