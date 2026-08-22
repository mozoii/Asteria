/// Control-stream message from the host (rumble, LED, triggers, HDR, termination).
public enum HostControlMessage: Sendable, Equatable {
    /// Dual-motor rumble (`SS_RUMBLE` / `IDX_RUMBLE_DATA`).
    case rumble(controllerNumber: UInt16, lowFreq: UInt16, highFreq: UInt16)
    /// Trigger rumble (`IDX_RUMBLE_TRIGGER_DATA`, Sunshine).
    case rumbleTriggers(controllerNumber: UInt16, leftTrigger: UInt16, rightTrigger: UInt16)
    /// Enable/disable motion reporting (0 Hz disables).
    case setMotionEventState(controllerNumber: UInt16, reportRateHz: UInt16, motionType: UInt8)
    /// Set the controller RGB LED (`IDX_SET_RGB_LED`, Sunshine).
    case setControllerLED(controllerNumber: UInt16, red: UInt8, green: UInt8, blue: UInt8)
    /// DualSense adaptive-trigger effect (10-byte payloads per trigger).
    case setAdaptiveTriggers(controllerNumber: UInt16, eventFlags: UInt8,
                             typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8])
    /// HDR mode toggle (`IDX_HDR_INFO`). The HDR metadata that follows is handled by the video path.
    case setHdrMode(enabled: Bool)
    /// Session termination with the host's (normalized) error code (`IDX_TERMINATION`).
    case termination(errorCode: UInt32)
    /// A control message we don't model (kept so the router can log/ignore it).
    case unknown(type: UInt16, payload: [UInt8])
}

/// Decodes host control messages from (type, payload).
public enum HostControlDecoder {
    // Inbound control-message types (host→client, gen7 encrypted — `packetTypesGen7Enc`).
    static let rumbleType: UInt16 = 0x010b
    static let rumbleTriggersType: UInt16 = 0x5500
    static let setMotionType: UInt16 = 0x5501
    static let setLedType: UInt16 = 0x5502
    static let setAdaptiveTriggersType: UInt16 = 0x5503
    static let hdrType: UInt16 = 0x010e
    static let terminationType: UInt16 = 0x0109

    /// DualSense per-trigger effect payload size.
    static let dsEffectSize = 10

    public static func decode(type: UInt16, payload: [UInt8]) -> HostControlMessage {
        switch type {
        case rumbleType:
            guard payload.count >= 10 else { return .unknown(type: type, payload: payload) }
            return .rumble(controllerNumber: le16(payload, 4), lowFreq: le16(payload, 6), highFreq: le16(payload, 8))

        case rumbleTriggersType:
            guard payload.count >= 6 else { return .unknown(type: type, payload: payload) }
            return .rumbleTriggers(controllerNumber: le16(payload, 0),
                                   leftTrigger: le16(payload, 2), rightTrigger: le16(payload, 4))

        case setMotionType:
            guard payload.count >= 5 else { return .unknown(type: type, payload: payload) }
            return .setMotionEventState(controllerNumber: le16(payload, 0),
                                        reportRateHz: le16(payload, 2), motionType: payload[4])

        case setLedType:
            guard payload.count >= 5 else { return .unknown(type: type, payload: payload) }
            return .setControllerLED(controllerNumber: le16(payload, 0),
                                     red: payload[2], green: payload[3], blue: payload[4])

        case setAdaptiveTriggersType:
            guard payload.count >= 5 + 2 * dsEffectSize else { return .unknown(type: type, payload: payload) }
            let left = Array(payload[5 ..< 5 + dsEffectSize])
            let right = Array(payload[5 + dsEffectSize ..< 5 + 2 * dsEffectSize])
            return .setAdaptiveTriggers(controllerNumber: le16(payload, 0), eventFlags: payload[2],
                                        typeLeft: payload[3], typeRight: payload[4], left: left, right: right)

        case hdrType:
            guard payload.count >= 1 else { return .unknown(type: type, payload: payload) }
            return .setHdrMode(enabled: payload[0] != 0)

        case terminationType:
            guard payload.count >= 4 else { return .unknown(type: type, payload: payload) }
            return .termination(errorCode: be32(payload, 0))

        default:
            return .unknown(type: type, payload: payload)
        }
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }
    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }
}
