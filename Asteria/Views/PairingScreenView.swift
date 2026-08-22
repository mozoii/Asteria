import SwiftUI
import AsteriaKit

/// The onboarding-style pairing dial: a rotating PIN ring with live status and "Get a new PIN"
/// retry. Shared between the first-run onboarding and pairing an existing host.
struct PairingDial: View {
    var coordinator: PairingCoordinator?

    @State private var pin = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Pair with \(coordinator?.host.displayName ?? "your PC")")
                .font(.system(size: 22, weight: .semibold))
                .padding(.bottom, 24)
            dial
            HStack(spacing: 6) {
                Text("Enter this code in Sunshine at")
                Text("\(coordinator?.host.address ?? "localhost"):47990")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(AsteriaTheme.surface, in: .rect(cornerRadius: 6))
                Text("→ PIN tab")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.top, 24)
            status.padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: phaseKey) { _, _ in
            if case let .awaitingPIN(p, _)? = coordinator?.phase { pin = p }
        }
    }

    private var dial: some View {
        let phase = coordinator?.phase ?? .preparing
        let paired = { if case .paired = phase { return true }; return false }()
        let failed = { if case .failed = phase { return true }; return false }()
        let verifying = { if case .verifying = phase { return true }; return false }()
        let active = !paired && !failed
        let arcColor: Color = paired ? .green : (failed ? Color.white.opacity(0.12) : AsteriaTheme.accent)
        let labelText = failed ? "Code expired" : (paired ? "Paired" : "Pairing PIN")
        let value = pin.isEmpty ? "••••" : pin
        return ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 4)
            if active {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(arcColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 3) / 3 * 360))
                }
            } else {
                Circle().stroke(arcColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            VStack(spacing: 7) {
                HStack(spacing: 5) {
                    if active { Image(systemName: "lock").font(.system(size: 9, weight: .semibold)) }
                    Text(labelText.uppercased()).tracking(1.5)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(failed ? Color.red.opacity(0.85) : (paired ? .green : .secondary))
                Text(value).font(.system(size: 40, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white).opacity(verifying ? 0.5 : 1)
            }
        }
        .frame(width: 220, height: 220)
    }

    @ViewBuilder private var status: some View {
        switch coordinator?.phase {
        case .verifying:
            statusRow(color: AsteriaTheme.accent, systemImage: nil,
                      text: "Verifying with \(coordinator?.host.displayName ?? "your PC")…", showSpinner: true)
        case .paired:
            statusRow(color: .green, systemImage: "checkmark.circle.fill", text: "Paired")
        case .failed(let message):
            VStack(spacing: 12) {
                statusRow(color: .red, systemImage: "xmark.circle.fill", text: message)
                Button("Get a new PIN") { Task { await coordinator?.start() } }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .buttonStyle(.plain).background(AsteriaTheme.accent, in: .capsule)
            }
        default:
            statusRow(color: .secondary, systemImage: nil, text: "Waiting for you to enter this PIN…",
                      showSpinner: true)
        }
    }

    private func statusRow(color: Color, systemImage: String?, text: String, showSpinner: Bool = false) -> some View {
        HStack(spacing: 9) {
            if showSpinner { ProgressView().controlSize(.small) }
            else if let systemImage { Image(systemName: systemImage).foregroundStyle(color) }
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var phaseKey: String {
        switch coordinator?.phase {
        case .preparing: return "preparing"
        case .awaitingPIN(let p, _): return "pin:\(p)"
        case .verifying: return "verifying"
        case .paired: return "paired"
        case .failed(let m): return "failed:\(m)"
        case nil: return "none"
        }
    }
}

/// Full-screen pairing flow shown when pairing or re-pairing a host. Mirrors the onboarding
/// pairing step and returns automatically shortly after pairing succeeds.
struct PairingScreenView: View {
    let coordinator: PairingCoordinator
    var onClose: () -> Void

    @State private var started = false

    var body: some View {
        PairingDial(coordinator: coordinator)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                Button { onClose() } label: { Label("Cancel", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                    .padding(20)
            }
            .overlay(alignment: .bottom) {
                ControllerHintBar(hints: [ControllerHint(glyph: .b, label: "Cancel")])
            }
            .background(AsteriaTheme.background)
        .foregroundStyle(.white)
        .task {
            guard !started, !isRunningInPreview else { return }
            started = true
            await coordinator.start()
        }
        .onChange(of: isPaired) { _, paired in
            guard paired else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))   // let the green "Paired" state land
                onClose()
            }
        }
    }

    private var isPaired: Bool { if case .paired = coordinator.phase { return true }; return false }
}

#if DEBUG
private let pairingPreviewHost = HostRecord(id: "uid-new", name: "DESKTOP-AB12CD", address: "192.168.1.23")

#Preview("Awaiting PIN") {
    PairingScreenView(coordinator: .preview(host: pairingPreviewHost,
        phase: .awaitingPIN(pin: "0427", deadline: Date().addingTimeInterval(300))), onClose: {})
        .frame(width: 900, height: 640)
}

#Preview("Verifying") {
    PairingScreenView(coordinator: .preview(host: pairingPreviewHost, phase: .verifying), onClose: {})
        .frame(width: 900, height: 640)
}

#Preview("Paired") {
    let fingerprint = ClientFingerprint(rawValue: String(repeating: "a", count: 64))!
    PairingScreenView(coordinator: .preview(host: pairingPreviewHost,
        phase: .paired(fingerprint: fingerprint)), onClose: {})
        .frame(width: 900, height: 640)
}

#Preview("Failed") {
    let message = "Pairing timed out. Make sure you entered the PIN on the PC in time."
    PairingScreenView(coordinator: .preview(host: pairingPreviewHost,
        phase: .failed(message: message)), onClose: {})
        .frame(width: 900, height: 640)
}
#endif
