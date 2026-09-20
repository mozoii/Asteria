import SwiftUI
import AppKit
import AsteriaKit

/// Live colour picking for the DualSense/DualShock light bar.
///
/// The shared colour panel, not a sheet: it updates continuously as the user drags, so the light bar
/// follows the cursor and the choice can be judged against the actual controller.
@MainActor
private final class PlayStationLEDColorPanel: NSObject {
    static let shared = PlayStationLEDColorPanel()
    private var onChange: ((PlayStationLEDColor) -> Void)?

    func present(_ color: PlayStationLEDColor, onChange: @escaping (PlayStationLEDColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.color = NSColor(red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                              blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.opacity) / 255)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let rgb = panel.color.usingColorSpace(.sRGB) else { return }
        onChange?(PlayStationLEDColor(red: Self.byte(rgb.redComponent),
                                      green: Self.byte(rgb.greenComponent),
                                      blue: Self.byte(rgb.blueComponent),
                                      opacity: Self.byte(rgb.alphaComponent)))
    }

    private static func byte(_ value: CGFloat) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded())
    }
}

extension View {
    func ledColorPicker(isPresented: Binding<Bool>, color: PlayStationLEDColor,
                        onChange onPick: @escaping (PlayStationLEDColor) -> Void) -> some View {
        onChange(of: isPresented.wrappedValue) { _, presenting in
            guard presenting else { return }
            PlayStationLEDColorPanel.shared.present(color, onChange: onPick)
            // The panel is modeless, so the request is consumed as soon as it is on screen.
            isPresented.wrappedValue = false
        }
    }
}
