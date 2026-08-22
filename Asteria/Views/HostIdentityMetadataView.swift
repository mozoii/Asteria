import SwiftUI
import AsteriaKit

/// Compact host software and client certificate identity shown across PC views.
struct HostIdentityMetadataView: View {
    let hostSoftware: HostSoftware
    let fingerprint: ClientFingerprint?

    var body: some View {
        HStack(spacing: 10) {
            Label(hostSoftware.displayName, systemImage: "server.rack")
                .help("Host software: \(hostSoftware.displayName)")
            if let fingerprint {
                Label {
                    Text(fingerprint.shortDisplay).fontDesign(.monospaced)
                } icon: {
                    Image(systemName: "touchid")
                }
                .textSelection(.enabled)
                .help("Client fingerprint: \(fingerprint.rawValue.uppercased())")
            }
        }
    }
}
