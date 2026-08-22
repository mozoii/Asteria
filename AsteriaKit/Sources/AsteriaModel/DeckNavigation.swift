/// Directional step within a deck (d-pad / arrow keys). Activation, back, and section switching
/// stay with the caller — this module owns only the cursor.
public enum DeckDir: Sendable {
    case up, down, left, right
}

/// Pure 2D cursor over a deck's rows of focusable items. Owns the cursor and all clamping;
/// the caller supplies the live layout and performs per-item activation.
public struct DeckCursor<Focus: Hashable & Sendable>: Sendable {
    private var row = 0
    private var col = 0
    public private(set) var highlight: Focus?

    public init() {}

    /// Recompute the rendered highlight from the cursor against the live layout, clamping to it.
    /// A vanished or empty row falls back to the nearest non-empty one.
    public mutating func syncHighlight(_ rows: [[Focus]]) {
        guard let target = nearestCell(to: (row, col), in: rows) else { highlight = nil; return }
        row = target.row
        col = target.col
        highlight = rows[row][col]
    }

    /// Land on the first focusable item: the first content row (index 1) when the deck has
    /// chrome plus content, the chrome row otherwise.
    public mutating func focusFirst(_ rows: [[Focus]]) {
        let contentRow = rows.count > 1 ? 1 : 0
        row = rows.indices.contains(contentRow) && !rows[contentRow].isEmpty ? contentRow : 0
        col = 0
        syncHighlight(rows)
    }

    /// Move one step through a ragged grid; the column clamps to the destination row's width.
    public mutating func step(_ dir: DeckDir, rows: [[Focus]]) {
        guard !rows.isEmpty else { highlight = nil; return }
        switch dir {
        case .up: row = max(0, row - 1)
        case .down: row = min(rows.count - 1, row + 1)
        case .left: col = max(0, col - 1)
        case .right: col += 1
        }
        syncHighlight(rows)
    }

    /// Nearest non-empty cell from the cursor: the cursor's own row when it has content, else
    /// the nearest non-empty row above or below, column clamped to its width.
    private func nearestCell(to cursor: (Int, Int), in rows: [[Focus]]) -> (row: Int, col: Int)? {
        guard !rows.isEmpty else { return nil }
        for delta in 0..<rows.count {
            let down = cursor.0 + delta
            if rows.indices.contains(down), !rows[down].isEmpty {
                return (down, min(max(0, cursor.1), rows[down].count - 1))
            }
            let up = cursor.0 - delta
            if up != down, rows.indices.contains(up), !rows[up].isEmpty {
                return (up, min(max(0, cursor.1), rows[up].count - 1))
            }
        }
        return nil
    }
}
