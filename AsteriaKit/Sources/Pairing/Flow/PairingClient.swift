import Foundation

/// Orchestrates the 5-stage GameStream PIN pairing over a `GameStreamTransport`.
public actor PairingClient {
    /// Spec'd pairing deadline: the user has this long to type the PIN into the host before we abort.
    public static let defaultTimeoutSeconds: Double = 300

    private let transport: GameStreamTransport
    private let identity: ClientIdentity
    private let deviceName: String
    private let uniqueId: String

    /// The host's certificate (DER), captured during stage 1 — pin this for the HTTPS control channel.
    public private(set) var serverCertificateDER: [UInt8]?

    public init(
        transport: GameStreamTransport,
        identity: ClientIdentity,
        deviceName: String = "roth",
        uniqueId: String? = nil
    ) {
        self.transport = transport
        self.identity = identity
        self.deviceName = deviceName
        self.uniqueId = uniqueId ?? Hex.encode(PairingRandom.bytes(8))
    }

    /// Run the full handshake; user must enter `pin` into the host concurrently. Aborts with `.timedOut` if the handshake exceeds `timeoutSeconds`.
    public func pair(
        pin: String,
        salt providedSalt: [UInt8]? = nil,
        pinEntryDelaySeconds: Double = 0,
        finishWithHTTPS: Bool = true,
        timeoutSeconds: Double = PairingClient.defaultTimeoutSeconds
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.runHandshake(
                    pin: pin, salt: providedSalt,
                    pinEntryDelaySeconds: pinEntryDelaySeconds, finishWithHTTPS: finishWithHTTPS
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000))
                throw PairingError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func runHandshake(
        pin: String,
        salt providedSalt: [UInt8]?,
        pinEntryDelaySeconds: Double,
        finishWithHTTPS: Bool
    ) async throws {
        let salt = providedSalt ?? PairingRandom.bytes(16)
        var flow = try PairingFlow(
            identity: identity,
            handshake: PairingHandshake(aesKey: PairingCrypto.aesKey(salt: salt, pin: pin)),
            deviceName: deviceName,
            uniqueId: uniqueId,
            salt: salt,
            clientChallenge: PairingRandom.bytes(16),
            clientSecret: PairingRandom.bytes(16)
        )

        try flow.ingestServerCert(try await transport.get(flow.clientCertRequest()))
        if let der = flow.serverCertificateDER {
            serverCertificateDER = der
            transport.setPinnedServerCertificate(der)
        }

        if pinEntryDelaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(pinEntryDelaySeconds * 1_000_000_000))
        }

        try flow.ingestChallengeResponse(try await transport.get(flow.clientChallengeRequest()))
        try flow.ingestPairingSecret(try await transport.get(flow.serverChallengeRespRequest()))
        try flow.ingestPairedConfirmation(try await transport.get(flow.clientPairingSecretRequest()))

        // Stage 5 requires mutual-TLS.
        if !finishWithHTTPS { return }
        try flow.ingestPairChallenge(try await transport.get(flow.pairChallengeRequest()))
    }
}
