import Foundation

/// One finger currently on the glass. `id` only has to be stable for the life of a touch.
public struct TouchPoint: Equatable, Sendable {
    public let id: Int
    public let x: Double
    public let y: Double

    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// What a touch gesture asks the host to do. The app maps these onto the input sink; keeping them as
/// values means the classification can be tested without a device.
public enum TouchCommand: Equatable, Sendable {
    /// Pointer motion in view points, for Game mode's relative route.
    case moveRelative(dx: Double, dy: Double)
    /// Pointer position in view points, for Desktop mode's absolute route.
    case moveAbsolute(x: Double, y: Double)
    case leftButton(down: Bool)
    case rightButton(down: Bool)
    case scroll(dx: Double, dy: Double)
    /// Three-finger tap: the gesture that reaches the overlay menu with no keyboard or controller.
    case openMenu
}

/// Turns raw touches into pointer commands: a trackpad, in the absence of one.
///
/// A phone has no mouse and no keyboard, so without this a player could start a stream and then have
/// no way to click, scroll, or even reach the menu to end it. The rules follow a laptop trackpad
/// closely enough that they don't need explaining: drag moves, tap clicks, two fingers are the right
/// button and the scroll wheel, and a press that outlasts the tap window holds the button down for
/// dragging. Three fingers open the menu.
///
/// The caller feeds snapshots of every touch that is down, plus a `tick` while they stay down so a
/// long press can fire without further movement.
public struct TouchPointerModel: Sendable {
    public struct Tuning: Sendable {
        /// How far a touch may drift and still count as a tap rather than a drag, in points.
        public var tapSlop: Double
        /// Longest a tap may last. Beyond this a stationary touch becomes a held button.
        public var tapMaxSeconds: Double
        /// When a stationary touch starts holding the left button down, for drag-and-drop.
        public var longPressSeconds: Double
        /// Finger travel to host pointer travel. Above 1 so crossing a 4K desktop doesn't need
        /// several swipes; low enough that aiming stays possible.
        public var relativeScale: Double
        /// Two-finger travel to scroll delta. Negative so dragging down scrolls content down, which
        /// is the direction iOS itself uses.
        public var scrollScale: Double

        public init(tapSlop: Double = 10, tapMaxSeconds: Double = 0.3,
                    longPressSeconds: Double = 0.5, relativeScale: Double = 1.5,
                    scrollScale: Double = -1) {
            self.tapSlop = tapSlop
            self.tapMaxSeconds = tapMaxSeconds
            self.longPressSeconds = longPressSeconds
            self.relativeScale = relativeScale
            self.scrollScale = scrollScale
        }

        public static let defaults = Tuning()
    }

    /// Desktop mode drives an absolute pointer; Game mode drives relative deltas.
    public var usesAbsolutePointer: Bool

    private let tuning: Tuning

    private var activeIDs: Set<Int> = []
    /// Most fingers seen at once during this gesture; a two-finger tap rarely lands both at the same
    /// instant, and releasing one first must not reclassify it as a one-finger tap.
    private var peakCount = 0
    private var startTime: Double = 0
    private var startCentroid: (x: Double, y: Double) = (0, 0)
    private var lastCentroid: (x: Double, y: Double) = (0, 0)
    private var movedBeyondSlop = false
    private var holdingLeftButton = false

    public init(usesAbsolutePointer: Bool = false, tuning: Tuning = .defaults) {
        self.usesAbsolutePointer = usesAbsolutePointer
        self.tuning = tuning
    }

    /// True while any finger is down, so the caller knows whether to keep ticking.
    public var isTracking: Bool { !activeIDs.isEmpty }

    /// Feed every touch currently down. Returns what to send, in order.
    public mutating func update(touches: [TouchPoint], at time: Double) -> [TouchCommand] {
        let ids = Set(touches.map(\.id))
        guard !ids.isEmpty else { return finish(at: time) }

        let centroid = Self.centroid(of: touches)
        guard !activeIDs.isEmpty else {
            begin(ids: ids, centroid: centroid, at: time)
            return []
        }

        var commands: [TouchCommand] = []
        // A finger joining or leaving re-bases the centroid; without this the jump would read as a
        // large drag and fling the host pointer across the screen.
        if ids != activeIDs {
            activeIDs = ids
            peakCount = max(peakCount, ids.count)
            lastCentroid = centroid
            return []
        }

        let dx = centroid.x - lastCentroid.x
        let dy = centroid.y - lastCentroid.y
        lastCentroid = centroid
        if abs(centroid.x - startCentroid.x) > tuning.tapSlop
            || abs(centroid.y - startCentroid.y) > tuning.tapSlop {
            movedBeyondSlop = true
        }

        guard dx != 0 || dy != 0 else { return commands }
        switch ids.count {
        case 1:
            if usesAbsolutePointer {
                commands.append(.moveAbsolute(x: centroid.x, y: centroid.y))
            } else {
                commands.append(.moveRelative(dx: dx * tuning.relativeScale,
                                              dy: dy * tuning.relativeScale))
            }
        case 2:
            commands.append(.scroll(dx: dx * tuning.scrollScale, dy: dy * tuning.scrollScale))
        default:
            break   // three or more fingers are a menu gesture, not pointer motion
        }
        return commands
    }

    /// Call while fingers stay down so a stationary press can become a held button.
    public mutating func tick(at time: Double) -> [TouchCommand] {
        guard activeIDs.count == 1, peakCount == 1,
              !holdingLeftButton, !movedBeyondSlop,
              time - startTime >= tuning.longPressSeconds else { return [] }
        holdingLeftButton = true
        return [.leftButton(down: true)]
    }

    /// Abandon the gesture, releasing anything held. Used when the system cancels the touches.
    public mutating func cancel() -> [TouchCommand] {
        let commands: [TouchCommand] = holdingLeftButton ? [.leftButton(down: false)] : []
        reset()
        return commands
    }

    private mutating func begin(ids: Set<Int>, centroid: (x: Double, y: Double), at time: Double) {
        activeIDs = ids
        peakCount = ids.count
        startTime = time
        startCentroid = centroid
        lastCentroid = centroid
        movedBeyondSlop = false
        holdingLeftButton = false
    }

    private mutating func finish(at time: Double) -> [TouchCommand] {
        guard !activeIDs.isEmpty else { return [] }
        defer { reset() }

        if holdingLeftButton { return [.leftButton(down: false)] }
        guard !movedBeyondSlop, time - startTime <= tuning.tapMaxSeconds else { return [] }
        switch peakCount {
        case 1: return [.leftButton(down: true), .leftButton(down: false)]
        case 2: return [.rightButton(down: true), .rightButton(down: false)]
        case 3: return [.openMenu]
        default: return []
        }
    }

    private mutating func reset() {
        activeIDs = []
        peakCount = 0
        movedBeyondSlop = false
        holdingLeftButton = false
    }

    private static func centroid(of touches: [TouchPoint]) -> (x: Double, y: Double) {
        let count = Double(touches.count)
        return (touches.reduce(0) { $0 + $1.x } / count, touches.reduce(0) { $0 + $1.y } / count)
    }
}
