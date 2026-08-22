import SwiftUI
import AsteriaKit

/// Guided PIN pairing: shows the PIN to type on the PC, live progress, and success/failure with retry.
struct PairingView: View {
    let coordinator: PairingCoordinator
    var onClose: () -> Void

    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onClose() } label: { Label("Cancel", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
            }
            .padding(20)

            Spacer()
            content
            Spacer()

            ControllerHintBar(hints: hints)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AsteriaTheme.background)
        .foregroundStyle(.white)
        .task {
            guard !started, !isRunningInPreview else { return }
            started = true
            await coordinator.start()
        }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.phase {
        case .preparing:
            progress("Connecting to \(coordinator.host.displayName)…")

        case let .awaitingPIN(pin, _):
            VStack(spacing: 22) {
                Text("Pair with \(coordinator.host.displayName)").font(.title2.weight(.semibold))
                VStack(spacing: 8) {
                    Text("Enter this PIN on your PC").font(.subheadline).foregroundStyle(.secondary)
                    Text(pin)
                        .font(.system(size: 64, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .padding(.horizontal, 28).padding(.vertical, 16)
                        .background(AsteriaTheme.surface, in: .rect(cornerRadius: 18))
                }
                Text("Open Sunshine or Apollo on the PC. A prompt will ask for this PIN.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to enter the PIN…").font(.footnote).foregroundStyle(.secondary)
                }
                countdown
            }

        case .verifying:
            progress("Finishing up…")

        case .paired:
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("Paired with \(coordinator.host.displayName)").font(.title2.weight(.semibold))
                HostIdentityMetadataView(
                    hostSoftware: coordinator.host.hostSoftware,
                    fingerprint: coordinator.pairedFingerprint)
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Continue") { onClose() }
                    .buttonStyle(.borderedProminent)
            }

        case let .failed(message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)
                Text("Pairing unsuccessful").font(.title2.weight(.semibold))
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack {
                    Button("Back") { onClose() }
                    Button("Try again") { Task { await coordinator.start() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder private var countdown: some View {
        if case let .awaitingPIN(_, deadline) = coordinator.phase {
            let start = deadline.addingTimeInterval(-coordinator.pinTimeoutSeconds)
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(timerInterval: start...deadline, countsDown: true).monospacedDigit()
                Text("left to enter the PIN")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func progress(_ label: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(label).font(.title3).foregroundStyle(.secondary)
        }
    }

    private var hints: [ControllerHint] {
        switch coordinator.phase {
        case .paired: return [ControllerHint(glyph: .a, label: "Continue")]
        case .failed: return [ControllerHint(glyph: .a, label: "Try again"), ControllerHint(glyph: .b, label: "Back")]
        default: return [ControllerHint(glyph: .b, label: "Cancel")]
        }
    }
}

#if DEBUG
private let pairingPreviewHost = HostRecord(id: "uid-new", name: "DESKTOP-AB12CD", address: "192.168.1.23")

#Preview("Awaiting PIN") {
    PairingView(coordinator: .preview(host: pairingPreviewHost,
        phase: .awaitingPIN(pin: "0427", deadline: Date().addingTimeInterval(300))), onClose: {})
        .frame(width: 900, height: 640)
}

#Preview("Verifying") {
    PairingView(coordinator: .preview(host: pairingPreviewHost, phase: .verifying), onClose: {})
        .frame(width: 900, height: 640)
}

#Preview("Paired") {
    let fingerprint = ClientFingerprint(rawValue: String(repeating: "a", count: 64))!
    PairingView(coordinator: .preview(host: pairingPreviewHost,
        phase: .paired(fingerprint: fingerprint)), onClose: {})
        .frame(width: 900, height: 640)
}

#Preview("Failed") {
    let message = "Pairing timed out. Make sure you entered the PIN on the PC in time."
    PairingView(coordinator: .preview(host: pairingPreviewHost,
        phase: .failed(message: message)), onClose: {})
        .frame(width: 900, height: 640)
}
#endif
