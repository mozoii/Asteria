import Foundation

/// Encodes input events into GameStream control-stream packets.
public enum InputEncoder {
    /// Control-stream message type that wraps every input packet (gen7 encrypted: `IDX_INPUT_DATA`).
    public static let inputDataType: UInt16 = 0x0206

    /// `SS_KBE_FLAG_NON_NORMALIZED` — tell the host the keycode is not a standard US-English scancode
    /// and must be interpreted as-is (set for the keymap's `nonNormalized` keys). Sunshine extension.
    public static let keyboardFlagNonNormalized: UInt8 = 0x01

    public static let modifierShift: UInt8 = 0x01
    public static let modifierCtrl: UInt8 = 0x02
    public static let modifierAlt: UInt8 = 0x04
    public static let modifierMeta: UInt8 = 0x08

    public static let mouseButtonLeft: UInt8 = 0x01
    public static let mouseButtonMiddle: UInt8 = 0x02
    public static let mouseButtonRight: UInt8 = 0x03
    public static let mouseButtonX1: UInt8 = 0x04
    public static let mouseButtonX2: UInt8 = 0x05

    /// One `WHEEL_DELTA` of scroll (a single notch), matching Win32. `LiSendScrollEvent` clicks × this.
    public static let wheelDelta: Int16 = 120

    /// An encoded input packet, ready to hand to `ControlStream.send`.
    public struct Packet: Sendable, Equatable {
        /// The raw `NV_INPUT_HEADER`+body bytes (the control-message payload).
        public let payload: [UInt8]
        /// The ENet channel this packet is sent on (`CTRL_CHANNEL_*`).
        public let channel: UInt8

        public init(payload: [UInt8], channel: UInt8) {
            self.payload = payload
            self.channel = channel
        }

        /// The control-stream message wrapping this input packet (`type` = `inputDataType`).
        public var message: ControlMessage.Message { (InputEncoder.inputDataType, payload) }
    }

    /// Relative pointer motion (deltas big-endian; host clamps to Int16).
    public static func mouseMoveRelative(deltaX: Int16, deltaY: Int16) -> Packet {
        Packet(payload: packet(magic: 0x00000007, body: be16(deltaX) + be16(deltaY)),
               channel: channelMouse)
    }

    /// Absolute pointer position. Send `width−1`/`height−1` to work around GFE edge-rounding.
    public static func mouseMoveAbsolute(x: Int16, y: Int16,
                                         referenceWidth: Int16, referenceHeight: Int16) -> Packet {
        let body = be16(x) + be16(y) + [0, 0]
            + be16(referenceWidth &- 1) + be16(referenceHeight &- 1)
        return Packet(payload: packet(magic: 0x00000005, body: body), channel: channelMouse)
    }

    /// Mouse button down/up.
    public static func mouseButton(_ button: UInt8, down: Bool) -> Packet {
        Packet(payload: packet(magic: down ? 0x00000008 : 0x00000009, body: [button]),
               channel: channelMouse)
    }

    /// High-resolution vertical scroll (amount in WHEEL_DELTA units).
    public static func scrollVertical(amount: Int16) -> Packet {
        Packet(payload: packet(magic: 0x0000000A, body: be16(amount) + be16(amount) + [0, 0]),
               channel: channelMouse)
    }

    /// High-resolution horizontal scroll (Sunshine extension).
    public static func scrollHorizontal(amount: Int16) -> Packet {
        Packet(payload: packet(magic: 0x55000001, body: be16(amount)), channel: channelMouse)
    }

    /// Key down/up. `keyCode` is a Win32 VK code (little-endian).
    public static func keyboard(keyCode: Int16, down: Bool, modifiers: UInt8, flags: UInt8 = 0) -> Packet {
        let body = [flags] + le16(keyCode) + [modifiers] + [0, 0]
        return Packet(payload: packet(magic: down ? 0x00000003 : 0x00000004, body: body),
                      channel: channelKeyboard)
    }

    /// Per-frame controller state. Low 16 bits in `buttonFlags`; high 16 in `buttonFlags2` (Sunshine).
    public static func multiController(index: UInt8, activeMask: UInt16, buttonFlags: UInt32,
                                       leftTrigger: UInt8, rightTrigger: UInt8,
                                       leftStickX: Int16, leftStickY: Int16,
                                       rightStickX: Int16, rightStickY: Int16) -> Packet {
        var body = [UInt8]()
        body += le16u(0x001A)
        body += le16u(UInt16(index))
        body += le16u(activeMask)
        body += le16u(0x0014)
        body += le16u(UInt16(buttonFlags & 0xFFFF))
        body += [leftTrigger, rightTrigger]
        body += le16(leftStickX) + le16(leftStickY)
        body += le16(rightStickX) + le16(rightStickY)
        body += le16u(0x009C)
        body += le16u(UInt16((buttonFlags >> 16) & 0xFFFF))
        body += le16u(0x0055)
        return Packet(payload: packet(magic: 0x0000000C, body: body),
                      channel: channelGamepad(index))
    }

    /// Controller hotplug announcement (Sunshine). Required before honoring multiController for a new pad.
    public static func controllerArrival(index: UInt8, type: UInt8,
                                         supportedButtonFlags: UInt32, capabilities: UInt16) -> Packet {
        let body = [index, type] + le16u(capabilities) + le32(supportedButtonFlags)
        return Packet(payload: packet(magic: 0x55000004, body: body), channel: channelGamepad(index))
    }

    /// Controller battery report (Sunshine). `percentage` is 0–100 or 0xFF for unknown.
    public static func controllerBattery(index: UInt8, state: UInt8, percentage: UInt8) -> Packet {
        Packet(payload: packet(magic: 0x55000007, body: [index, state, percentage, 0]),
               channel: channelGamepad(index))
    }

    /// Enable haptics. Host won't send rumble until it receives this.
    public static func enableHaptics() -> Packet {
        Packet(payload: packet(magic: 0x0000000D, body: le16u(1)), channel: ControlMessage.channelGeneric)
    }

    public static let channelKeyboard: UInt8 = 0x02
    public static let channelMouse: UInt8 = 0x03
    /// Controller events per pad (0x10…0x1F).
    public static let channelGamepadBase: UInt8 = 0x10
    /// Motion sensors per pad (0x20…0x2F).
    public static let channelSensorBase: UInt8 = 0x20

    public static func channelGamepad(_ index: UInt8) -> UInt8 { channelGamepadBase + index }
    public static func channelSensor(_ index: UInt8) -> UInt8 { channelSensorBase + index }

    /// Prepend NV_INPUT_HEADER: size (BE32) + magic (LE32).
    private static func packet(magic: UInt32, body: [UInt8]) -> [UInt8] {
        var p = [UInt8]()
        p.reserveCapacity(8 + body.count)
        p += be32(UInt32(4 + body.count))
        p += le32(magic)
        p += body
        return p
    }

    private static func be16(_ v: Int16) -> [UInt8] {
        let u = UInt16(bitPattern: v)
        return [UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    }
    private static func le16(_ v: Int16) -> [UInt8] {
        let u = UInt16(bitPattern: v)
        return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF)]
    }
    private static func le16u(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }
    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
