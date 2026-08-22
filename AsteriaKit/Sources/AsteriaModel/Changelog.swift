import Foundation

public enum ChangeKind: String, Codable, Sendable, CaseIterable, Hashable {
    case new, improved, fixed, removed, known, experimental

    public var displayLabel: String {
        switch self {
        case .new: return "New"
        case .improved: return "Improved"
        case .fixed: return "Fixed"
        case .removed: return "Removed"
        case .known: return "Known Issue"
        case .experimental: return "Experimental"
        }
    }
}

public struct ChangeItem: Codable, Sendable, Equatable {
    public let kind: ChangeKind
    public let symbol: String
    public let title: String
    public let text: String

    public init(kind: ChangeKind, symbol: String, title: String, text: String? = nil) {
        self.kind = kind
        self.symbol = symbol
        self.title = title
        self.text = text.map { $0.isEmpty ? title : $0 } ?? title
    }

    /// A title-only entry omits `text`; it then falls back to the title so the row still has copy.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let title = try c.decode(String.self, forKey: .title)
        let text = try c.decodeIfPresent(String.self, forKey: .text)
        self.init(kind: try c.decode(ChangeKind.self, forKey: .kind),
                  symbol: try c.decode(String.self, forKey: .symbol),
                  title: title, text: text)
    }
}

/// One release's notes: the content of `docs/changelogs/<version>.json` in the repo.
public struct ReleaseEntry: Codable, Sendable, Equatable {
    public let version: String
    public let items: [ChangeItem]

    public init(version: String, items: [ChangeItem]) {
        self.version = version
        self.items = items
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(ReleaseEntry.self, from: data)
    }

    /// Items sorted into canonical category order (New, Improved, Fixed, …).
    public func orderedItems() -> [ChangeItem] {
        let order = ChangeKind.allCases
        return items.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }
}
