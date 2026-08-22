import Foundation
import AsteriaModel
import Pairing

/// Observable progress of one pairing attempt, from identity creation through the handshake
/// to persistence. The UI renders this directly; it holds no pairing logic of its own.
public enum PairingProgress: Sendable, Equatable {
    case preparing
    case awaitingPIN(pin: String, deadline: Date)
    case verifying
    case paired(fingerprint: ClientFingerprint)
    case failed(message: String)
}

/// Tunables for one guided pairing flow.
public struct PairingSessionConfiguration: Sendable {
    public var deviceName: String
    public var pinTimeoutSeconds: Double

    public init(deviceName: String = "Asteria",
                pinTimeoutSeconds: Double = PairingClient.defaultTimeoutSeconds) {
        self.deviceName = deviceName
        self.pinTimeoutSeconds = pinTimeoutSeconds
    }
}

/// Internal seams: the live transport/pin/identity generators, swapped for fakes in tests.
struct PairingSessionDependencies: Sendable {
    var identityFactory: @Sendable () throws -> ClientIdentity = { try ClientIdentity.generate() }
    var transportFactory: @Sendable (HostRecord, ClientIdentity) throws -> any GameStreamTransport
    var pinGenerator: @Sendable () -> String
}

/// The guided pairing flow behind one interface: identity creation, PIN + deadline, the 5-stage
/// handshake, and persistence (Keychain identity + host record).
public final class PairingSession: Sendable {
    public let host: HostRecord
    public let configuration: PairingSessionConfiguration

    private let identities: ClientIdentityVault
    private let onPaired: @Sendable (HostRecord) async -> Void
    private let dependencies: PairingSessionDependencies

    public convenience init(host: HostRecord,
                            identities: ClientIdentityVault,
                            onPaired: @escaping @Sendable (HostRecord) async -> Void,
                            configuration: PairingSessionConfiguration = .init()) {
        self.init(
            host: host,
            identities: identities,
            onPaired: onPaired,
            configuration: configuration,
            dependencies: PairingSessionDependencies(
                identityFactory: { try identities.create() },
                transportFactory: { host, identity in
                    try GameStreamHTTPTransport(host: host.address, identity: identity)
                },
                pinGenerator: { PairingRandom.pin() }
            )
        )
    }

    init(host: HostRecord,
         identities: ClientIdentityVault,
         onPaired: @escaping @Sendable (HostRecord) async -> Void,
         configuration: PairingSessionConfiguration = .init(),
         dependencies: PairingSessionDependencies) {
        self.host = host
        self.identities = identities
        self.onPaired = onPaired
        self.configuration = configuration
        self.dependencies = dependencies
    }

    /// Run one attempt off the caller's actor; the stream ends when the attempt finishes
    /// (or when the caller drops it).
    public func run() -> AsyncStream<PairingProgress> {
        AsyncStream { continuation in
            let attempt = Task.detached { [self] in
                await runAttempt(continuation)
            }
            continuation.onTermination = { _ in attempt.cancel() }
        }
    }

    private func runAttempt(_ continuation: AsyncStream<PairingProgress>.Continuation) async {
        continuation.yield(.preparing)
        do {
            let identity = try dependencies.identityFactory()
            let transport = try dependencies.transportFactory(host, identity)
            let pin = dependencies.pinGenerator()
            let deadline = Date().addingTimeInterval(configuration.pinTimeoutSeconds)
            continuation.yield(.awaitingPIN(pin: pin, deadline: deadline))

            let client = PairingClient(transport: transport, identity: identity,
                                       deviceName: configuration.deviceName,
                                       uniqueId: identity.uniqueId)
            try await client.pair(pin: pin, timeoutSeconds: configuration.pinTimeoutSeconds)
            continuation.yield(.verifying)

            guard let cert = await client.serverCertificateDER else {
                fail(continuation, "The PC didn't return its certificate. Try pairing again.")
                return
            }
            try identities.save(identity)
            var updated = host
            updated.markPaired(
                pinnedCertificate: Data(cert), clientFingerprint: identity.fingerprint)
            await onPaired(updated)
            continuation.yield(.paired(fingerprint: identity.fingerprint))
        } catch {
            fail(continuation, PairingError.userMessage(for: error))
        }
        continuation.finish()
    }

    private func fail(_ continuation: AsyncStream<PairingProgress>.Continuation,
                      _ message: String) {
        continuation.yield(.failed(message: message))
    }
}

public extension PairingError {
    /// Canonical user text for any error surfaced to the user, pairing or otherwise.
    static func userMessage(for error: Error) -> String {
        if let pairing = error as? PairingError { return pairing.userMessage }
        return error.localizedDescription
    }
}
