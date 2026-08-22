import Foundation
import AsteriaCore

/// An app/game advertised by the host.
public struct GameApp: Sendable, Equatable {
    public let id: String
    public let title: String
}

public enum AppListParser {
    public static func parse(_ data: Data) -> [GameApp] {
        guard let xml = try? FlatXML(parsing: data) else { return [] }
        return xml.records("App").compactMap { app in
            guard let id = app.value("ID"), !id.isEmpty else { return nil }
            return GameApp(id: id, title: app.value("AppTitle") ?? "")
        }
    }
}
