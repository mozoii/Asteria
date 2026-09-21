import AppKit
import SwiftUI

/// The standard macOS About panel, reached from the app menu. iOS has no app menu; the same
/// information lives in Settings → About, which both platforms show.
enum AboutPanel {
    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            // Empty build version suppresses the "(build)" parenthetical.
            .version: "",
            .credits: credits(),
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static func credits() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 3
        para.lineSpacing = 1

        let font = NSFont.systemFont(ofSize: 11)
        let secondary: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor, .font: font, .paragraphStyle: para,
        ]

        func text(_ string: String) -> NSAttributedString {
            NSAttributedString(string: string, attributes: secondary)
        }

        let credits = NSMutableAttributedString()
        credits.append(text("A low-latency, local, open-source game streaming client for macOS.\n\n"))
        let free = NSMutableAttributedString(string: "Asteria is free", attributes: secondary)
        free.addAttribute(.link, value: URL(string: "https://github.com/mozoii/Asteria")!,
                          range: NSRange(location: 0, length: free.length))
        credits.append(free)
        credits.append(text(
            " and open-source software, licensed under GPLv3.\n" +
            "Third-party licenses can be found in the About section under settings."
        ))
        return credits
    }
}

extension Scene {
    /// Mac-only window sizing and the About menu item.
    func asteriaPlatformScene() -> some Scene {
        windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About Asteria") { AboutPanel.show() }
                }
            }
    }
}
