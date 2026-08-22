import SwiftUI
import GameController
import AsteriaKit

/// True when rendering inside an Xcode preview canvas — used to skip live network scans.
var isRunningInPreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

/// Dark console palette + metrics shared across the app shell.
enum AsteriaTheme {
    static let background = Color(red: 0.028, green: 0.035, blue: 0.049)
    static let surface = Color.white.opacity(0.06)
    static let surfaceFocused = Color.white.opacity(0.14)
    static let accent = Color(red: 0.851, green: 0.173, blue: 0.325)   // #d92c53
    static let pillTrack = Color(red: 0.114, green: 0.114, blue: 0.133)
    static let cardCorner: CGFloat = 16
}

extension View {
    /// Custom focus ring (white + crimson glow); macOS won't draw a system focus ring for @State-driven views.
    @ViewBuilder func controllerFocusRing(_ on: Bool, radius: CGFloat = 11) -> some View {
        overlay {
            if on {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white, lineWidth: 2.5)
                    .shadow(color: AsteriaTheme.accent.opacity(0.85), radius: 4)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: on)
    }
}

/// A controller button shown in the hint bar, rendered as its glyph.
enum ControllerGlyph {
    case a, b, x, y, shoulders, dpad, menu
    case symbol(String)
}

/// One button-prompt shown in the persistent on-screen hint bar (gamepad-native navigation aid).
struct ControllerHint: Identifiable {
    let id = UUID()
    let glyph: ControllerGlyph
    let label: String
}

/// Bottom bar of controller button hints — shown only while a controller is connected.
struct ControllerHintBar: View {
    let hints: [ControllerHint]
    @State private var controller: GCController?

    var body: some View {
        Group {
            if isRunningInPreview || controller != nil {
                HStack(spacing: 22) {
                    ForEach(hints) { hint in
                        HStack(spacing: 7) {
                            ControllerGlyphView(glyph: hint.glyph, controller: controller)
                            Text(hint.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(.black.opacity(0.3))
            }
        }
        .onAppear(perform: refreshController)
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            refreshController()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            refreshController()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidBecomeCurrent)) { _ in
            refreshController()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .GCControllerUserCustomizationsDidChange)
        ) { _ in
            refreshController()
        }
    }

    private func refreshController() {
        controller = GCController.current ?? GCController.controllers().first
    }
}

/// Renders a controller button as the active controller's glyph when available.
struct ControllerGlyphView: View {
    let glyph: ControllerGlyph
    let controller: GCController?

    var body: some View {
        switch glyph {
        case .a:
            faceButton(extendedGamepad?.buttonA, fallback: "A",
                       color: Color(red: 0.36, green: 0.72, blue: 0.30))
        case .b:
            faceButton(extendedGamepad?.buttonB, fallback: "B",
                       color: Color(red: 0.83, green: 0.27, blue: 0.24))
        case .x:
            faceButton(extendedGamepad?.buttonX, fallback: "X",
                       color: Color(red: 0.20, green: 0.47, blue: 0.85))
        case .y:
            faceButton(extendedGamepad?.buttonY, fallback: "Y",
                       color: Color(red: 0.92, green: 0.73, blue: 0.16), textColor: .black)
        case .shoulders: shoulder
        case .dpad: controllerElementGlyph(extendedGamepad?.dpad, fallback: "dpad.fill")
        case .menu:
            controllerElementGlyph(extendedGamepad?.buttonMenu, fallback: "line.3.horizontal")
        case let .symbol(name): Image(systemName: name).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var extendedGamepad: GCExtendedGamepad? {
        guard let controller, controller.isPlayStationController else { return nil }
        return controller.extendedGamepad
    }

    @ViewBuilder private func faceButton(_ element: GCControllerElement?, fallback: String,
                                         color: Color, textColor: Color = .white) -> some View {
        if let symbol = element?.sfSymbolsName {
            controllerSymbol(symbol)
        } else {
            face(fallback, color, textColor: textColor)
        }
    }

    @ViewBuilder private func controllerElementGlyph(_ element: GCControllerElement?,
                                                      fallback: String) -> some View {
        if let symbol = element?.sfSymbolsName {
            controllerSymbol(symbol)
        } else {
            controllerSymbol(fallback)
        }
    }

    private func controllerSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 20, weight: .medium))
            .frame(width: 20, height: 20)
            .foregroundStyle(.secondary)
    }

    private func face(_ letter: String, _ color: Color, textColor: Color = .white) -> some View {
        Text(letter)
            .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(textColor)
            .frame(width: 20, height: 20)
            .background(color, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    @ViewBuilder private var shoulder: some View {
        if let left = extendedGamepad?.leftShoulder.sfSymbolsName,
           let right = extendedGamepad?.rightShoulder.sfSymbolsName {
            HStack(spacing: 3) {
                controllerSymbol(left)
                Text("/").foregroundStyle(.secondary)
                controllerSymbol(right)
            }
        } else {
            Text("LB / RB")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 7).frame(height: 20)
                .background(Color.white.opacity(0.16), in: .rect(cornerRadius: 6))
        }
    }
}
