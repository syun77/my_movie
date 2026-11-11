import Foundation

struct EditSnapshot: Equatable {
    var lyrics = LyricsTrack()
    var visuals = VisualTrack()
    var settings = SceneSettings()
}

@MainActor
final class EditHistory {
    private struct Entry {
        let before: EditSnapshot
        var after: EditSnapshot
        let group: UUID?
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    private(set) var current = EditSnapshot()
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    func reset(_ value: EditSnapshot) {
        current = value; past = []; future = []
    }
    func record(_ value: EditSnapshot, group: UUID? = nil) {
        guard value != current else { return }
        if let group, past.last?.group == group {
            past[past.count - 1].after = value
            if past.last?.before == value { past.removeLast() }
        } else {
            past.append(Entry(before: current, after: value, group: group))
        }
        current = value; future.removeAll()
    }
    func undo() -> EditSnapshot? {
        guard let entry = past.popLast() else { return nil }
        future.append(entry); current = entry.before
        return current
    }
    func redo() -> EditSnapshot? {
        guard let entry = future.popLast() else { return nil }
        past.append(entry); current = entry.after
        return current
    }
}
