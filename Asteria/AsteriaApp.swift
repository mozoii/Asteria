import SwiftUI
import AppKit
import AsteriaKit

@main
struct AsteriaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(AsteriaTheme.accent)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Asteria") {
                    Self.showAboutPanel()
                }
            }
        }
    }

    private static func showAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            // Empty build version suppresses the "(build)" parenthetical.
            .version: "",
            .credits: aboutCredits(),
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static func aboutCredits() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 3
        para.lineSpacing = 1

        let font = NSFont.systemFont(ofSize: 11)
        let secondary: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor, .font: font, .paragraphStyle: para,
        ]

        func text(_ string: String) -> NSAttributedString { NSAttributedString(string: string, attributes: secondary) }

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
