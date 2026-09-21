import SwiftUI
import AsteriaKit

/// Live colour picking for the DualSense/DualShock light bar. iOS has no modeless colour panel, so
/// this is a sheet; the binding still updates continuously while the wheel is dragged, so the light
/// bar follows along the same way the Mac's panel does.
private struct LEDColorPickerSheet: ViewModifier {
    @Binding var isPresented: Bool
    let color: PlayStationLEDColor
    let onChange: (PlayStationLEDColor) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            NavigationStack {
                ColorPicker("LED color", selection: Binding(
                    get: { Color(red: Double(color.red) / 255,
                                 green: Double(color.green) / 255,
                                 blue: Double(color.blue) / 255)
                        .opacity(Double(color.opacity) / 255) },
                    set: { onChange(Self.ledColor(from: $0)) }
                ), supportsOpacity: true)
                .padding()
                .navigationTitle("LED color")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPresented = false }
                    }
                }
            }
            .presentationDetents([.height(180)])
        }
    }

    private static func ledColor(from color: Color) -> PlayStationLEDColor {
        let components = UIColor(color).cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?
            .components ?? [0, 0, 0, 1]
        func byte(_ index: Int) -> UInt8 {
            guard index < components.count else { return 255 }
            return UInt8((min(max(components[index], 0), 1) * 255).rounded())
        }
        return PlayStationLEDColor(red: byte(0), green: byte(1), blue: byte(2), opacity: byte(3))
    }
}

extension View {
    func ledColorPicker(isPresented: Binding<Bool>, color: PlayStationLEDColor,
                        onChange: @escaping (PlayStationLEDColor) -> Void) -> some View {
        modifier(LEDColorPickerSheet(isPresented: isPresented, color: color, onChange: onChange))
    }
}
