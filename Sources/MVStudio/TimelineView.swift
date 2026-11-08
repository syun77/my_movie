import AppKit

@MainActor
final class TimelineView: NSView {
    var imageMode = false { didSet { cancelDrag(); setAccessibilityLabel(imageMode ? "再生位置付近の画像タイムライン" : "再生位置付近の歌詞タイムライン"); needsDisplay = true } }
    var images = ImageTrack() { didSet { needsDisplay = true } }
    var missingAssets = Set<UUID>() { didSet { needsDisplay = true } }
    var selectedImageID: UUID? { didSet { needsDisplay = true } }
    var selectedSlot = 1 { didSet { needsDisplay = true } }
    var onImageSelect: ((UUID?, Int) -> Void)?
    var onImagePreview: ((ImageTrack) -> Void)?
    var onImageCommit: ((ImageTrack, UUID) -> Void)?
    var onDropImage: ((URL, Int, Double) -> Void)?
    private var imageDrag: ImageDrag?
    private var dropGeometry: TimelineGeometry?
    private var dropCandidate: (slot: Int, start: Double, end: Double)?
    private struct ImageDrag {
        let original: ImageTrack
        let geometry: TimelineGeometry
        let id: UUID
        let part: TimelineDragPart
        let initialX: Double
        var draft: ImageTrack
        var hasDragged = false
        var targetSlot: Int?
        var error: String?
    }
    var snapGrid = TimelineSnapGrid() { didSet { cancelDrag(); needsDisplay = true } }
    var track = LyricsTrack() { didSet { needsDisplay = true } }
    var currentTime = 0.0 { didSet { needsDisplay = true } }
    var duration = 0.0 { didSet { needsDisplay = true } }
    var visibleSpan = TimelineDisplaySettings.defaultSpan { didSet { needsDisplay = true } }
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
        drag?.geometry ?? imageDrag?.geometry ?? dropGeometry ?? scrubGeometry ?? TimelineGeometry(time: currentTime, duration: duration, span: visibleSpan, width: max(1, bounds.width - Self.gutter))
    }
    static let gutter = 78.0
    private let clipY = 39.0
    private let clipHeight = 44.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        identifier = NSUserInterfaceItemIdentifier("placement.timeline")
        toolTip = "本体を左右で時刻移動、画像本体を上下でレイヤー移動。左右端で開始・終了を調整。空白や目盛りでシーク。Escで取り消し。"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("再生位置付近の歌詞タイムライン")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 1).setFill(); bounds.fill()
        if imageMode { drawImages(); return }
        let geometry = geometry
        let displayed = drag?.draft ?? track
        let interval = geometry.tickInterval
        var time = ceil(geometry.origin / interval) * interval
        while time <= min(duration, geometry.origin + geometry.span) + 1e-9 {
            let x = x(at: time)
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: 24)); line.line(to: NSPoint(x: x, y: 87)); line.stroke()
            label(TimelineGeometry.label(time), rect: NSRect(x: x + 3, y: 6, width: 78, height: 15), color: .lightGray, size: 10)
            time += interval
        }
        for clip in displayed.clips where clip.end > geometry.origin && clip.start < geometry.origin + geometry.span {
            let left = x(at: clip.start), right = x(at: clip.end)
            let rect = NSRect(x: left, y: clipY, width: right - left, height: clipHeight)
            let visible = rect.intersection(NSRect(x: Self.gutter + TimelineGeometry.inset, y: 0, width: max(0, bounds.width - Self.gutter - 2 * TimelineGeometry.inset), height: bounds.height))
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
        let playhead = x(at: currentTime)
        if playhead >= 0 && playhead <= bounds.width {
            NSColor.systemPink.setStroke()
            let line = NSBezierPath(); line.lineWidth = 2
            line.move(to: NSPoint(x: playhead, y: 23)); line.line(to: NSPoint(x: playhead, y: 88)); line.stroke()
        }
        let footer = duration > 0 ? "再生位置 \(TimelineGeometry.label(currentTime))　｜　本体：移動　端：開始/終了　16分音符スナップ　Esc：取消" : "音声を読み込むと、再生位置の周辺と歌詞の表示区間を確認できます"
        label(footer, rect: NSRect(x: 14, y: 92, width: bounds.width - 28, height: 16), color: .lightGray, size: 10)
    }

    func x(at time: Double) -> Double { Self.gutter + geometry.x(at: time) }

    private func label(_ text: String, rect: NSRect, color: NSColor, size: CGFloat) {
        guard rect.width > 0 else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    private func hit(at point: NSPoint, geometry: TimelineGeometry) -> (LyricClip, TimelineDragPart)? {
        guard point.y >= clipY && point.y <= clipY + clipHeight else { return nil }
        for clip in track.clips {
            let left = x(at: clip.start), right = x(at: clip.end)
            guard point.x >= max(Self.gutter + TimelineGeometry.inset, left) && point.x <= min(bounds.width - TimelineGeometry.inset, right) else { continue }
            let startDistance = abs(point.x - left), endDistance = abs(point.x - right)
            if min(startDistance, endDistance) <= 8 { return (clip, startDistance <= endDistance ? .start : .end) }
            return (clip, .move)
        }
        return nil
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, window?.makeFirstResponder(self) != false else { return }
        if imageMode { imageMouseDown(event); return }
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
        if imageMode { imageMouseDragged(event); return }
        let point = convert(event.locationInWindow, from: nil)
        if var value = drag {
            do {
                value.draft = try value.original.dragging(id: value.id, part: value.part, delta: (point.x - value.initialX) / value.geometry.pointsPerSecond, duration: duration, grid: snapGrid)
                drag = value; onPreview?(value.draft); needsDisplay = true
            } catch { onError?(error) }
        } else if let frozen = scrubGeometry { seek(at: point.x, geometry: frozen) }
    }
    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        if imageMode { imageMouseUp(event); return }
        if let value = drag {
            drag = nil
            if value.original != value.draft { onCommit?(value.draft, value.id) }
        }
        scrubGeometry = nil; needsDisplay = true
    }
    private func seek(at x: Double, geometry: TimelineGeometry) { onSeek?(max(0, min(duration, geometry.time(at: x - Self.gutter)))) }
    func cancelDrag() {
        if let value = drag { drag = nil; onPreview?(value.original) }
        if let value = imageDrag { imageDrag = nil; NSCursor.arrow.set(); onImagePreview?(value.original) }
        dropGeometry = nil; dropCandidate = nil
        scrubGeometry = nil; needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelDrag() } else { super.keyDown(with: event) }
    }
    override func resetCursorRects() {
        guard isEnabled else { return }
        guard !imageMode else { return }
        for clip in track.clips {
            let left = x(at: clip.start), right = x(at: clip.end)
            let rect = NSRect(x: left, y: clipY, width: right - left, height: clipHeight).intersection(bounds)
            guard !rect.isEmpty else { continue }
            addCursorRect(rect, cursor: .openHand)
            for x in [left, right - 8] {
                let handle = NSRect(x: x, y: clipY, width: 8, height: clipHeight).intersection(bounds)
                if !handle.isEmpty { addCursorRect(handle, cursor: .resizeLeftRight) }
            }
        }
    }

    private func slot(at point: NSPoint) -> Int? {
        guard point.y >= 48, point.y < 186 else { return nil }
        return 3 - Int((point.y - 48) / 46)
    }
    private func rowY(_ slot: Int) -> Double { 48 + Double(3 - slot) * 46 }
    private func imageRect(_ clip: ImageClip, slot: Int) -> NSRect {
        NSRect(x: x(at: clip.start), y: rowY(slot) + 3, width: x(at: clip.end) - x(at: clip.start), height: 39)
    }
    private func drawImages() {
        let clipBounds = NSRect(x: Self.gutter + TimelineGeometry.inset, y: 0, width: max(0, bounds.width - Self.gutter - 2 * TimelineGeometry.inset), height: bounds.height)
        let displayed = imageDrag?.draft ?? images
        for slot in 1...3 {
            if slot == (imageDrag?.targetSlot ?? selectedSlot) { NSColor.white.withAlphaComponent(0.04).setFill(); NSRect(x: 0, y: rowY(slot), width: bounds.width, height: 46).fill() }
            label("画像\(slot)" + (slot == 3 ? " 前" : slot == 1 ? " 後" : ""), rect: NSRect(x: 5, y: rowY(slot) + 14, width: 70, height: 18), color: .lightGray, size: 11)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clipBounds).addClip()
        let interval = geometry.tickInterval
        var time = ceil(geometry.origin / interval) * interval
        while time <= min(duration, geometry.origin + geometry.span) + 1e-9 {
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: x(at: time), y: 24)); line.line(to: NSPoint(x: x(at: time), y: 186)); line.stroke()
            label(TimelineGeometry.label(time), rect: NSRect(x: x(at: time) + 2, y: 4, width: 80, height: 16), color: .lightGray, size: 10)
            time += interval
        }
        for lyric in track.clips where lyric.end > geometry.origin && lyric.start < geometry.origin + geometry.span {
            let rect = NSRect(x: x(at: lyric.start), y: 25, width: x(at: lyric.end) - x(at: lyric.start), height: 161)
            NSColor.systemYellow.withAlphaComponent(0.10).setFill(); rect.fill()
            NSColor.systemYellow.withAlphaComponent(0.25).setStroke()
            let edge = NSBezierPath(); edge.setLineDash([3, 3], count: 2, phase: 0)
            for x in [rect.minX, rect.maxX] { edge.move(to: NSPoint(x: x, y: 25)); edge.line(to: NSPoint(x: x, y: 186)) }; edge.stroke()
            label(lyric.text.replacingOccurrences(of: "\n", with: " "), rect: NSRect(x: rect.minX + 3, y: 27, width: max(0, rect.width - 6), height: 16), color: .systemYellow.withAlphaComponent(0.4), size: 10)
        }
        for layer in displayed.layers {
            for clip in layer.clips {
                let rect = imageRect(clip, slot: layer.slot).intersection(clipBounds)
                guard !rect.isEmpty else { continue }
                let missing = missingAssets.contains(clip.assetID)
                (missing ? NSColor.systemRed : NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.57, alpha: 1)).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 0), xRadius: 4, yRadius: 4).fill()
                if clip.id == selectedImageID { NSColor.cyan.setStroke(); NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).stroke() }
                label((missing ? "⚠ " : "") + (displayed.asset(clip.assetID)?.name ?? "不明"), rect: NSRect(x: rect.minX + 8, y: rect.minY + 3, width: max(0, rect.width - 16), height: 17), color: .white, size: 11)
                label("\(TimelineGeometry.label(clip.start)) → \(TimelineGeometry.label(clip.end))", rect: NSRect(x: rect.minX + 8, y: rect.minY + 22, width: max(0, rect.width - 16), height: 13), color: .white, size: 9)
                NSColor.white.withAlphaComponent(0.6).setFill()
                for edge in [x(at: clip.start) + 3, x(at: clip.end) - 5] { NSRect(x: edge, y: rect.minY + 12, width: 2, height: 15).fill() }
            }
        }
        if let drag = imageDrag, drag.error != nil, let slot = drag.targetSlot, let clip = drag.original.clip(drag.id) {
            NSColor.systemRed.setStroke()
            let outline = NSBezierPath(roundedRect: imageRect(clip, slot: slot).insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            outline.lineWidth = 2; outline.stroke()
        }
        if let candidate = dropCandidate {
            NSColor.cyan.withAlphaComponent(0.35).setFill()
            NSRect(x: x(at: candidate.start), y: rowY(candidate.slot) + 3, width: x(at: candidate.end) - x(at: candidate.start), height: 39).fill()
        }
        NSColor.systemPink.setStroke()
        let head = NSBezierPath(); head.lineWidth = 2; head.move(to: NSPoint(x: x(at: currentTime), y: 23)); head.line(to: NSPoint(x: x(at: currentTime), y: 186)); head.stroke()
        NSGraphicsContext.restoreGraphicsState()
        label(imageDrag?.error ?? "本体：左右で時刻移動・上下で段移動　端：開始/終了　16分音符スナップ　Esc：取消", rect: NSRect(x: 14, y: 191, width: bounds.width - 28, height: 16), color: .lightGray, size: 10)
    }
    private func imageMouseDown(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let frozen = geometry
        if let slot = slot(at: point) {
            selectedSlot = slot
            if point.x >= Self.gutter, let clip = images.layers.first(where: { $0.slot == slot })?.clips.first(where: { imageRect($0, slot: slot).contains(point) }) {
                selectedImageID = clip.id; onImageSelect?(clip.id, slot)
                let left = abs(point.x - x(at: clip.start)), right = abs(point.x - x(at: clip.end))
                let part: TimelineDragPart = min(left, right) <= 8 ? (left <= right ? .start : .end) : .move
                onBeginEdit?()
                imageDrag = ImageDrag(original: images, geometry: frozen, id: clip.id, part: part, initialX: point.x, draft: images, targetSlot: slot, error: nil)
                return
            }
            selectedImageID = nil; onImageSelect?(nil, slot)
        }
        guard point.x >= Self.gutter else { return }
        onBeginEdit?(); scrubGeometry = frozen; seek(at: point.x, geometry: frozen)
    }
    private func imageMouseDragged(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if var drag = imageDrag {
            drag.hasDragged = true
            drag.targetSlot = drag.part == .move ? slot(at: point) : drag.original.slot(of: drag.id)
            do {
                guard slot(at: point) != nil, let destination = drag.targetSlot, point.x >= Self.gutter, point.x <= bounds.width - TimelineGeometry.inset else {
                    throw StudioError.message("画像行の上で離してください。範囲外では移動を取り消します。")
                }
                if drag.part == .move, destination != drag.original.slot(of: drag.id), let clip = drag.original.clip(drag.id) {
                    drag.draft = try drag.original.updating(clip, slot: destination, duration: duration)
                } else {
                    drag.draft = try drag.original.dragging(id: drag.id, part: drag.part, delta: (point.x - drag.initialX) / drag.geometry.pointsPerSecond, duration: duration, grid: snapGrid)
                }
                drag.error = nil
                NSCursor.closedHand.set()
            } catch {
                drag.draft = drag.original; drag.error = error.localizedDescription
                NSCursor.operationNotAllowed.set(); onError?(error)
            }
            imageDrag = drag; onImagePreview?(drag.draft); needsDisplay = true
        } else if let geometry = scrubGeometry { seek(at: point.x, geometry: geometry) }
    }
    private func imageMouseUp(_ event: NSEvent) {
        if imageDrag?.hasDragged == true { imageMouseDragged(event) }
        NSCursor.arrow.set()
        if let drag = imageDrag {
            imageDrag = nil
            if drag.original != drag.draft { onImageCommit?(drag.draft, drag.id) }
        }
        scrubGeometry = nil; needsDisplay = true
    }
    private func droppedURL(_ pasteboard: NSPasteboard) -> URL? {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard objects.count == 1, let url = objects.first, ["png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard imageMode, isEnabled, imageDrag == nil, drag == nil else { return [] }
        dropGeometry = geometry
        return draggingUpdated(sender)
    }
    func fileDrop(at point: NSPoint, pasteboard: NSPasteboard) throws -> (url: URL, slot: Int, start: Double, end: Double) {
        guard imageMode, isEnabled, imageDrag == nil, drag == nil, let url = droppedURL(pasteboard),
              point.x >= Self.gutter + TimelineGeometry.inset, point.x <= bounds.width - TimelineGeometry.inset,
              let slot = slot(at: point) else { throw StudioError.message("画像を1枚ずつ、配置可能な画像行の空白にドロップしてください。") }
        let range = try images.placement(at: geometry.time(at: point.x - Self.gutter), slot: slot, duration: duration, grid: snapGrid)
        return (url, slot, range.start, range.end)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropCandidate = nil; needsDisplay = true
        do {
            let value = try fileDrop(at: convert(sender.draggingLocation, from: nil), pasteboard: sender.draggingPasteboard)
            dropCandidate = (value.slot, value.start, value.end)
            return .copy
        } catch { return [] }
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropGeometry = nil; dropCandidate = nil; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingUpdated(sender) == .copy }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { draggingExited(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingUpdated(sender) == .copy, let candidate = dropCandidate, let url = droppedURL(sender.draggingPasteboard) else {
            onError?(StudioError.message("画像を1枚ずつ、配置可能な画像行の空白にドロップしてください。")); draggingExited(sender); return false
        }
        onBeginEdit?()
        onDropImage?(url, candidate.slot, candidate.start)
        draggingExited(sender)
        return true
    }
}
