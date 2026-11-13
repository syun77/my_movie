import AppKit

enum SpineLaneAction { case selection, blend, remove }

/// Editing state for a categorical animation lane or a continuous blend lane.
@MainActor final class SpineTimelineLane: NSObject {
    struct Configuration {
        let track: VisualTrack
        let clip: VisualClip
        let descriptor: SpineAssetDescriptor
        let slot: Int
        let rect: CGRect
        let viewport: CGRect
        let geometry: TimelineGeometry
        var plot: CGRect { rect.insetBy(dx: 0, dy: 8) }
    }
    var onCommit: ((VisualTrack, UUID) -> Void)?
    var onPreview: ((VisualTrack) -> Void)?
    var onBegin: (() -> Void)?
    var onSelect: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onAction: ((SpineLaneAction) -> Void)?
    var onDisplay: (() -> Void)?
    private(set) var selectedKeyID: UUID?
    private var config: Configuration?
    private var hover: NSPoint?
    private struct Drag {
        let config: Configuration
        let initial: CGPoint
        let keyID: UUID?
        let bendID: UUID?
        var draft: VisualTrack?
        var changed = false
    }
    private var drag: Drag?
    var frozenGeometry: TimelineGeometry? { drag?.config.geometry }
    func configure(_ next: Configuration?) {
        guard drag == nil else { return }
        if config?.clip.id != next?.clip.id { selectedKeyID = nil }
        config = next
        if let selectedKeyID, next?.clip.content.spinePlayback?.keyIDs.contains(selectedKeyID) != true {
            self.selectedKeyID = nil
        }
    }
    func clearSelection() { selectedKeyID = nil }
    func mouseMoved(_ point: NSPoint?) { hover = point }
    func cancel() {
        if let drag {
            self.drag = nil
            onPreview?(drag.config.track)
        }
        onDisplay?()
    }
    private func x(_ time: Double, _ c: Configuration) -> Double {
        TimelineView.gutter + c.geometry.x(at: c.clip.start + time)
    }
    private func y(_ value: Double, _ c: Configuration) -> Double {
        c.plot.maxY - min(1, max(0, value)) * c.plot.height
    }
    private func names(_ c: Configuration) -> [String] { c.descriptor.animations.map(\.name) }
    private func nameY(_ name: String, _ c: Configuration) -> Double {
        let list = names(c)
        guard let index = list.firstIndex(of: name), list.count > 1 else { return c.plot.midY }
        return c.plot.minY + Double(index) / Double(list.count - 1) * c.plot.height
    }
    private func name(at point: CGPoint, _ c: Configuration) -> String {
        names(c).enumerated().min { a, b in
            let da = abs(nameY(a.element, c) - point.y)
            let db = abs(nameY(b.element, c) - point.y)
            return da == db ? a.offset < b.offset : da < db
        }?.element ?? c.clip.content.spinePlayback!.animationName
    }
    private func value(at point: CGPoint, _ c: Configuration) -> Double {
        min(1, max(0, (c.plot.maxY - point.y) / c.plot.height))
    }
    private func keyPositions(_ c: Configuration) -> [(UUID, CGPoint)] {
        guard let playback = c.clip.content.spinePlayback else { return [] }
        switch playback.mode {
        case .selection(_, let keys):
            return keys.filter { (0...(c.clip.end - c.clip.start)).contains($0.time) }.map {
                ($0.id, CGPoint(x: x($0.time, c), y: nameY($0.animationName, c)))
            }
        case .blend(let blend):
            return blend.keys.filter { c.clip.containsKey($0) }.map {
                ($0.id, CGPoint(x: x($0.time, c), y: y($0.value, c)))
            }
        case .single: return []
        }
    }
    private func key(at point: CGPoint, _ c: Configuration) -> UUID? {
        guard c.viewport.contains(point) else { return nil }
        return keyPositions(c).filter {
            c.viewport.insetBy(dx: -1, dy: -1).contains($0.1) && hypot($0.1.x - point.x, $0.1.y - point.y) <= 11
        }
        .min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }?.0
    }
    private func bends(_ c: Configuration) -> [(UUID, CGPoint)] {
        guard case .blend(let blend) = c.clip.content.spinePlayback?.mode else { return [] }
        return blend.keys.compactMap {
            guard let mid = blend.curve.midpoint(after: $0.id), (0...(c.clip.end - c.clip.start)).contains(mid.time)
            else { return nil }
            return ($0.id, CGPoint(x: x(mid.time, c), y: y(mid.value, c)))
        }
    }
    private func bend(at point: CGPoint, _ c: Configuration) -> UUID? {
        guard c.viewport.contains(point), key(at: point, c) == nil else { return nil }
        return bends(c).filter { hypot($0.1.x - point.x, $0.1.y - point.y) <= 11 }
            .min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }?.0
    }
    func tooltip(at point: CGPoint) -> String? {
        guard let c = config, c.rect.contains(point), point.x < TimelineView.gutter else { return nil }
        if case .blend(let blend) = c.clip.content.spinePlayback?.mode {
            return "下端0%: \(blend.minimumAnimation)\n上端100%: \(blend.maximumAnimation)\n右クリックでモードを変更"
        }
        return name(at: point, c) + "（右クリックでモードを変更）"
    }
    func draw() {
        guard let original = config else { return }
        var c = original
        if let draft = drag?.draft, let clip = draft.clip(original.clip.id) {
            c = Configuration(
                track: draft, clip: clip, descriptor: original.descriptor, slot: original.slot, rect: original.rect,
                viewport: original.viewport, geometry: original.geometry)
        }
        guard let playback = c.clip.content.spinePlayback else { return }
        func label(_ text: String, y: Double) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (text as NSString).draw(
                in: CGRect(x: 5, y: y - 7, width: TimelineView.gutter - 10, height: 15),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.lightGray,
                    .paragraphStyle: paragraph,
                ])
        }
        var levels: [Double] = []
        switch playback.mode {
        case .selection:
            for name in names(c) {
                let pos = nameY(name, c)
                levels.append(pos)
                label(name, y: pos)
            }
        case .blend(let blend):
            levels = [y(0, c), y(1, c)]
            label("0% " + blend.minimumAnimation, y: y(0, c))
            label("100% " + blend.maximumAnimation, y: y(1, c))
        case .single: return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: c.viewport).addClip()
        let left = max(c.viewport.minX, x(0, c))
        let right = min(c.viewport.maxX, x(c.clip.end - c.clip.start, c))
        guard right >= left else { return }
        NSColor.white.withAlphaComponent(0.16).setStroke()
        for level in levels {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: left, y: level))
            line.line(to: CGPoint(x: right, y: level))
            line.stroke()
        }
        let first = max(0, c.geometry.origin - c.clip.start)
        let last = min(c.clip.end - c.clip.start, c.geometry.origin + c.geometry.span - c.clip.start)
        guard last >= first else { return }
        var points: [CGPoint] = []
        switch playback.mode {
        case .selection(_, let keys):
            var current = playback.resolved(at: first).animation
            points.append(CGPoint(x: x(first, c), y: nameY(current, c)))
            for key in keys where key.time > first && key.time <= last {
                points.append(CGPoint(x: x(key.time, c), y: nameY(current, c)))
                current = key.animationName
                points.append(CGPoint(x: x(key.time, c), y: nameY(current, c)))
            }
            points.append(CGPoint(x: x(last, c), y: nameY(current, c)))
        case .blend(let blend):
            points = blend.samples(from: first, through: last, steps: max(1, Int(right - left) / 3)).map {
                CGPoint(x: x($0.time, c), y: y($0.value, c))
            }
        case .single: break
        }
        let line = NSBezierPath()
        line.lineWidth = 1.5
        for (i, point) in points.enumerated() { if i == 0 { line.move(to: point) } else { line.line(to: point) } }
        NSColor.cyan.setStroke()
        line.stroke()
        let hot = drag?.keyID ?? hover.flatMap { key(at: $0, c) }
        for (id, point) in keyPositions(c) {
            let radius = id == hot ? 6.0 : 4
            (id == hot ? NSColor.systemYellow : id == selectedKeyID ? .white : .cyan).setFill()
            let diamond = NSBezierPath()
            diamond.move(to: CGPoint(x: point.x, y: point.y - radius))
            diamond.line(to: CGPoint(x: point.x + radius, y: point.y))
            diamond.line(to: CGPoint(x: point.x, y: point.y + radius))
            diamond.line(to: CGPoint(x: point.x - radius, y: point.y))
            diamond.close()
            diamond.fill()
        }
        let hotBend = drag?.bendID ?? hover.flatMap { bend(at: $0, c) }
        for (id, point) in bends(c) {
            (id == hotBend ? NSColor.systemYellow : .cyan).setStroke()
            let circle = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            circle.lineWidth = 1.5
            circle.stroke()
        }
    }
    func mouseDown(_ point: CGPoint) -> Bool {
        guard let c = config, c.rect.contains(point), point.y >= c.viewport.minY, point.y <= c.viewport.maxY else {
            return false
        }
        if point.x < TimelineView.gutter { return true }
        guard c.viewport.contains(point), point.x >= x(0, c), point.x <= x(c.clip.end - c.clip.start, c) else {
            return true
        }
        let id = key(at: point, c)
        let bendID = bend(at: point, c)
        onBegin?()
        onSelect?()
        selectedKeyID = id
        drag = Drag(config: c, initial: point, keyID: id, bendID: bendID)
        onDisplay?()
        return true
    }
    func mouseDragged(_ point: CGPoint, grid: TimelineSnapGrid?, duration: Double) {
        guard var drag, let original = drag.config.clip.content.spinePlayback else { return }
        let c = drag.config
        var playback = original
        do {
            let rawTime = c.geometry.time(at: point.x - TimelineView.gutter)
            let time = c.clip.keyTime(at: rawTime, grid: grid) - c.clip.start
            switch playback.mode {
            case .selection(let base, let originalKeys):
                guard let id = drag.keyID, let i = originalKeys.firstIndex(where: { $0.id == id }) else { return }
                var keys = originalKeys
                if point.x != drag.initial.x { keys[i].time = time }
                if point.y != drag.initial.y { keys[i].animationName = name(at: point, c) }
                playback.mode = .selection(base: base, keys: keys)
            case .blend(var blend):
                var curve = blend.curve
                if let id = drag.bendID, let midpoint = curve.midpoint(after: id) {
                    curve.adjustMidpoint(
                        after: id,
                        handleValue: value(
                            at: CGPoint(x: point.x, y: y(midpoint.value, c) + point.y - drag.initial.y), c))
                } else if let id = drag.keyID, let originalKey = blend.keys.first(where: { $0.id == id }) {
                    try curve.move(
                        id: id, to: point.x == drag.initial.x ? originalKey.time : time,
                        value: point.y == drag.initial.y ? originalKey.value : value(at: point, c))
                } else {
                    return
                }
                blend.keys = curve.keys
                playback.mode = .blend(blend)
            case .single: return
            }
            var clip = c.clip
            clip.content = .spine(playback)
            drag.draft = try c.track.updating(clip, slot: c.slot, duration: duration)
        } catch {
            drag.draft = nil
            onError?(error)
        }
        drag.changed = true
        self.drag = drag
        onPreview?(drag.draft ?? c.track)
        onDisplay?()
    }
    func mouseUp(_ point: CGPoint, grid: TimelineSnapGrid?, duration: Double) -> Bool {
        guard let original = drag else { return false }
        if original.changed { mouseDragged(point, grid: grid, duration: duration) }
        guard let drag = self.drag else { return true }
        self.drag = nil
        let c = drag.config
        if drag.changed {
            if let draft = drag.draft, draft != c.track { onCommit?(draft, c.clip.id) } else { onPreview?(c.track) }
        } else if drag.keyID == nil, drag.bendID == nil, hypot(point.x - drag.initial.x, point.y - drag.initial.y) <= 5,
            var playback = c.clip.content.spinePlayback
        {
            let time =
                c.clip.keyTime(at: c.geometry.time(at: drag.initial.x - TimelineView.gutter), grid: grid) - c.clip.start
            switch playback.mode {
            case .selection(let base, let originalKeys):
                var keys = originalKeys
                if let i = keys.firstIndex(where: { abs($0.time - time) <= ImageCurve.timeTolerance }) {
                    keys[i].animationName = name(at: drag.initial, c)
                    selectedKeyID = keys[i].id
                } else {
                    let key = SpineAnimationKey(time: time, animationName: name(at: drag.initial, c))
                    keys.append(key)
                    selectedKeyID = key.id
                }
                keys.sort { $0.time < $1.time }
                playback.mode = .selection(base: base, keys: keys)
            case .blend(var blend):
                if let i = blend.keys.firstIndex(where: { abs($0.time - time) <= ImageCurve.timeTolerance }) {
                    blend.keys[i].value = value(at: drag.initial, c)
                    selectedKeyID = blend.keys[i].id
                } else {
                    let key = ImageKeyframe(time: time, value: value(at: drag.initial, c))
                    blend.keys.append(key)
                    selectedKeyID = key.id
                }
                blend.keys.sort { $0.time < $1.time }
                playback.mode = .blend(blend)
            case .single: break
            }
            commit(playback, c, duration: duration)
        }
        onDisplay?()
        return true
    }
    private func commit(_ playback: SpinePlayback, _ c: Configuration, duration: Double) {
        do {
            var clip = c.clip
            clip.content = .spine(playback)
            let track = try c.track.updating(clip, slot: c.slot, duration: duration)
            onCommit?(track, clip.id)
        } catch { onError?(error) }
    }
    var duration = 0.0
    func removeSelectedKey() -> Bool {
        guard let c = config, let id = selectedKeyID, var playback = c.clip.content.spinePlayback,
            playback.keyIDs.contains(id)
        else { return false }
        switch playback.mode {
        case .selection(let base, let keys): playback.mode = .selection(base: base, keys: keys.filter { $0.id != id })
        case .blend(var blend):
            blend.keys.removeAll { $0.id == id }
            playback.mode = .blend(blend)
        case .single: return false
        }
        onBegin?()
        commit(playback, c, duration: duration)
        selectedKeyID = nil
        return true
    }
    func menu(at point: CGPoint) -> NSMenu? {
        guard let c = config, c.rect.contains(point), point.y >= c.viewport.minY, point.y <= c.viewport.maxY else {
            return nil
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if point.x < TimelineView.gutter {
            for (title, action) in [
                ("アニメーション切替", SpineLaneAction.selection), ("2つのアニメーションでブレンド", .blend), ("レーンを削除", .remove),
            ] {
                let item = menu.addItem(withTitle: title, action: #selector(modeAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action
                if action == .blend {
                    item.isEnabled = names(c).count >= 2
                    if !item.isEnabled { item.toolTip = "ブレンドには2つ以上のアニメーションが必要です。" }
                }
                if action == .selection, case .selection = c.clip.content.spinePlayback?.mode { item.state = .on }
                if action == .blend, case .blend = c.clip.content.spinePlayback?.mode { item.state = .on }
            }
            return menu
        }
        guard let id = key(at: point, c) else { return nil }
        onSelect?()
        selectedKeyID = id
        onDisplay?()
        let delete = menu.addItem(withTitle: "削除", action: #selector(deleteKey), keyEquivalent: "")
        delete.target = self
        if case .blend(let blend) = c.clip.content.spinePlayback?.mode,
            let key = blend.keys.first(where: { $0.id == id })
        {
            menu.addItem(.separator())
            for interpolation in ImageInterpolation.allCases {
                let item = menu.addItem(
                    withTitle: interpolation.title, action: #selector(interpolationAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = interpolation
                item.state = key.incomingInterpolation == interpolation ? .on : .off
            }
        }
        return menu
    }
    @objc private func modeAction(_ item: NSMenuItem) {
        if let action = item.representedObject as? SpineLaneAction { onAction?(action) }
    }
    @objc private func deleteKey() { _ = removeSelectedKey() }
    @objc private func interpolationAction(_ item: NSMenuItem) {
        guard let c = config, let id = selectedKeyID, let interpolation = item.representedObject as? ImageInterpolation,
            var playback = c.clip.content.spinePlayback, case .blend(var blend) = playback.mode,
            let i = blend.keys.firstIndex(where: { $0.id == id })
        else { return }
        blend.keys[i].interpolation = interpolation == .single ? nil : interpolation
        playback.mode = .blend(blend)
        onBegin?()
        commit(playback, c, duration: duration)
    }
}
