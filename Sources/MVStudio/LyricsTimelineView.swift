import AppKit

@MainActor
final class LyricsTimelineView: NSView {
    var track = LyricsTrack() { didSet { needsDisplay = true } }
    var currentTime = 0.0 { didSet { needsDisplay = true } }
    var duration = 0.0 { didSet { needsDisplay = true } }
    var visibleSpan = 12.0 { didSet { needsDisplay = true } }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var isEnabled = false { didSet { if !isEnabled { cancelDrag() }; needsDisplay = true } }
    var onBeginEdit: (() -> Void)?
    var onSelect: ((UUID) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onPreview: ((LyricsTrack) -> Void)?
    var onCommit: ((LyricsTrack, UUID) -> Void)?
    var onError: ((Error) -> Void)?

    private struct Drag {
        let original: LyricsTrack
        let geometry: TimelineGeometry
        let id: UUID
        let part: TimelineDragPart
        let initialX: Double
        var draft: LyricsTrack
    }
    private var drag: Drag?
    private var scrubGeometry: TimelineGeometry?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var geometry: TimelineGeometry {
        drag?.geometry ?? scrubGeometry ?? TimelineGeometry(time: currentTime, duration: duration, span: visibleSpan, width: bounds.width)
    }
    private let clipY = 39.0
    private let clipHeight = 44.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("lyrics.timeline")
        toolTip = "本体をドラッグで移動、左右端で開始・終了を調整。空白や目盛りでシーク。Escで取り消し。"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("再生位置付近の歌詞タイムライン")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 1).setFill(); bounds.fill()
        let geometry = geometry
        let displayed = drag?.draft ?? track
        let interval = geometry.span <= 4 ? 0.25 : (geometry.span <= 8 ? 0.5 : (geometry.span <= 16 ? 1.0 : 2.0))
        var time = ceil(geometry.origin / interval) * interval
        while time <= min(duration, geometry.origin + geometry.span) + 1e-9 {
            let x = geometry.x(at: time)
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: 24)); line.line(to: NSPoint(x: x, y: 87)); line.stroke()
            label(TimelineGeometry.label(time), rect: NSRect(x: x + 3, y: 6, width: 78, height: 15), color: .lightGray, size: 10)
            time += interval
        }
        for clip in displayed.clips where clip.end > geometry.origin && clip.start < geometry.origin + geometry.span {
            let left = geometry.x(at: clip.start), right = geometry.x(at: clip.end)
            let rect = NSRect(x: left, y: clipY, width: right - left, height: clipHeight)
            let visible = rect.intersection(bounds.insetBy(dx: TimelineGeometry.inset, dy: 0))
            guard !visible.isEmpty else { continue }
            let selected = clip.id == selectedID
            NSColor(calibratedRed: selected ? 0.14 : 0.12, green: selected ? 0.55 : 0.32, blue: selected ? 0.68 : 0.43, alpha: 1).setFill()
            NSBezierPath(roundedRect: visible.insetBy(dx: 1, dy: 0), xRadius: 4, yRadius: 4).fill()
            if selected {
                NSColor.cyan.setStroke()
                NSBezierPath(roundedRect: visible.insetBy(dx: 1, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
            }
            let text = (clip.predecessorID == nil ? "" : "↳ ") + clip.text.replacingOccurrences(of: "\n", with: " / ")
            label(text, rect: visible.insetBy(dx: 10, dy: 5), color: .white, size: 12)
            label("\(TimelineGeometry.label(clip.start)) → \(TimelineGeometry.label(clip.end))", rect: NSRect(x: visible.minX + 10, y: clipY + 25, width: max(0, visible.width - 20), height: 14), color: .white.withAlphaComponent(0.8), size: 9)
            NSColor.white.withAlphaComponent(0.65).setFill()
            for x in [left + 3, right - 5] where x >= visible.minX && x + 2 <= visible.maxX {
                NSRect(x: x, y: clipY + 12, width: 2, height: 20).fill()
            }
        }
        let playhead = geometry.x(at: currentTime)
        if playhead >= 0 && playhead <= bounds.width {
            NSColor.systemPink.setStroke()
            let line = NSBezierPath(); line.lineWidth = 2
            line.move(to: NSPoint(x: playhead, y: 23)); line.line(to: NSPoint(x: playhead, y: 88)); line.stroke()
        }
        let footer = duration > 0 ? "再生位置 \(TimelineGeometry.label(currentTime))　｜　本体：移動　端：開始/終了　Esc：取消" : "音声を読み込むと、再生位置の周辺と歌詞の表示区間を確認できます"
        label(footer, rect: NSRect(x: 14, y: 92, width: bounds.width - 28, height: 16), color: .lightGray, size: 10)
    }

    private func label(_ text: String, rect: NSRect, color: NSColor, size: CGFloat) {
        guard rect.width > 0 else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    private func hit(at point: NSPoint, geometry: TimelineGeometry) -> (LyricClip, TimelineDragPart)? {
        guard point.y >= clipY && point.y <= clipY + clipHeight else { return nil }
        for clip in track.clips {
            let left = geometry.x(at: clip.start), right = geometry.x(at: clip.end)
            guard point.x >= max(TimelineGeometry.inset, left) && point.x <= min(bounds.width - TimelineGeometry.inset, right) else { continue }
            let startDistance = abs(point.x - left), endDistance = abs(point.x - right)
            if min(startDistance, endDistance) <= 8 { return (clip, startDistance <= endDistance ? .start : .end) }
            return (clip, .move)
        }
        return nil
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let frozen = geometry
        onBeginEdit?()
        if let (clip, part) = hit(at: point, geometry: frozen) {
            selectedID = clip.id; onSelect?(clip.id)
            drag = Drag(original: track, geometry: frozen, id: clip.id, part: part, initialX: point.x, draft: track)
        } else {
            scrubGeometry = frozen
            seek(at: point.x, geometry: frozen)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if var value = drag {
            do {
                value.draft = try value.original.dragging(id: value.id, part: value.part, delta: (point.x - value.initialX) / value.geometry.pointsPerSecond, duration: duration)
                drag = value; onPreview?(value.draft); needsDisplay = true
            } catch { onError?(error) }
        } else if let frozen = scrubGeometry { seek(at: point.x, geometry: frozen) }
    }
    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        if let value = drag {
            drag = nil
            if value.original != value.draft { onCommit?(value.draft, value.id) }
        }
        scrubGeometry = nil; needsDisplay = true
    }
    private func seek(at x: Double, geometry: TimelineGeometry) { onSeek?(max(0, min(duration, geometry.time(at: x)))) }
    func cancelDrag() {
        if let value = drag { drag = nil; onPreview?(value.original) }
        scrubGeometry = nil; needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelDrag() } else { super.keyDown(with: event) }
    }
    override func resetCursorRects() {
        guard isEnabled else { return }
        for clip in track.clips {
            let left = geometry.x(at: clip.start), right = geometry.x(at: clip.end)
            let rect = NSRect(x: left, y: clipY, width: right - left, height: clipHeight).intersection(bounds)
            guard !rect.isEmpty else { continue }
            addCursorRect(rect, cursor: .openHand)
            for x in [left, right - 8] {
                let handle = NSRect(x: x, y: clipY, width: 8, height: clipHeight).intersection(bounds)
                if !handle.isEmpty { addCursorRect(handle, cursor: .resizeLeftRight) }
            }
        }
    }
}
