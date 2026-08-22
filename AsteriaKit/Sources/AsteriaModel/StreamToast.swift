import Foundation

public enum StreamToastCategory: String, Codable, Equatable, Sendable {
    case adaptiveBitrate
    case audioMuted
    case audioUnmuted
}

public struct StreamToast: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let category: StreamToastCategory
    public let message: String

    public init(id: UUID = UUID(), category: StreamToastCategory, message: String) {
        self.id = id
        self.category = category
        self.message = message
    }
}

public struct StreamNotificationPolicy: Equatable, Sendable {
    public let systemAllowed: Bool
    public let adaptiveBitrateAllowed: Bool
    public let muteAllowed: Bool

    public init(systemAllowed: Bool, adaptiveBitrateAllowed: Bool, muteAllowed: Bool) {
        self.systemAllowed = systemAllowed
        self.adaptiveBitrateAllowed = adaptiveBitrateAllowed
        self.muteAllowed = muteAllowed
    }

    public func allows(_ category: StreamToastCategory) -> Bool {
        switch category {
        case .audioMuted, .audioUnmuted: return muteAllowed
        case .adaptiveBitrate:
            guard systemAllowed else { return false }
            return adaptiveBitrateAllowed
        }
    }
}

public struct StreamToastQueue: Equatable, Sendable {
    private var items: [StreamToast] = []

    public init() {}

    public var current: StreamToast? { items.first }
    public var count: Int { items.count }

    @discardableResult
    public mutating func enqueue(_ toast: StreamToast) -> Bool {
        guard !items.contains(where: {
            $0.category == toast.category && $0.message == toast.message
        }) else { return false }
        items.append(toast)
        return true
    }

    @discardableResult
    public mutating func dismissCurrent() -> StreamToast? {
        guard !items.isEmpty else { return nil }
        items.removeFirst()
        return items.first
    }

    public mutating func clear() { items.removeAll() }
}
