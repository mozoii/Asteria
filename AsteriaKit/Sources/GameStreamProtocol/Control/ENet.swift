import CENet

public enum ENet {
    private static let didInitialize: Bool = { enet_initialize() == 0 }()

    @discardableResult
    public static func initializeIfNeeded() -> Bool { didInitialize }

    public static var linkedVersion: UInt32 { UInt32(enet_linked_version()) }
}
