import AppKit

@MainActor
final class TimelineView: NSView {
    var imageMode = false { didSet { hoverPoint = nil; cancelDrag(); setAccessibilityLabel(imageMode ? "再生位置付近の画像タイムライン" : "再生位置付近の歌詞タイムライン"); needsDisplay = true } }
    var images = ImageTrack() {
        didSet {
            layerParameters = Dictionary(uniqueKeysWithValues: images.layers.map { layer in
                let used = Set(layer.clips.flatMap { $0.curves.map(\.parameter) })
                return (layer.slot, ImageParameter.allCases.filter { used.contains($0) })
            })
            updateGraphLayout()
        }
    }
    var automationPreview: ImageTrack? { didSet { needsDisplay = true } }
    var missingAssets = Set<UUID>() { didSet { needsDisplay = true } }
    var selectedImageID: UUID? {
        didSet {
            if oldValue != selectedImageID { selectGraph(nil) }
            updateGraphLayout()
        }
    }
    private(set) var expandedLayerSlots: Set<Int> = []
    private var layerParameters: [Int: [ImageParameter]] = [:]
    private(set) var selectedParameter: ImageParameter?
    private(set) var selectedKeyID: UUID?
    var onGraphSelection: (() -> Void)?
    var onGraphRangeEdit: ((Bool) -> Void)?
    var onWheelZoom: ((Double) -> Void)?
    var keySnapEnabled = true
    private var rowScroll = 0.0
    private let rowsTop = 48.0
    private let rowHeight = 46.0
    private let graphHeight = 62.0
    private var keyDrag: KeyDrag?
    private var hoverPoint: NSPoint?
    private let keyHitRadius = 11.0
    private let keyMarkerRadius = 4.0
    private let highlightedKeyRadius = 6.0

    private struct KeyDrag {
        let original: ImageTrack
        let geometry: TimelineGeometry
        let lane: GraphLane
        let key: ImageKeyframe?
        let initial: NSPoint
        let previousTime: Double
        var draft: ImageTrack?
        var changed = false
    }

    private struct GraphLane {
        let clip: ImageClip
        let curve: ImageCurve
        let rect: NSRect

        func value(at y: Double) -> Double {
            let fraction = min(1, max(0, (rect.maxY - y) / rect.height))
            return curve.minimum + fraction * (curve.maximum - curve.minimum)
        }

        func y(at value: Double) -> Double {
            let fraction = (min(curve.maximum, max(curve.minimum, value)) - curve.minimum) / (curve.maximum - curve.minimum)
            return rect.maxY - fraction * rect.height
        }
    }
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
        drag?.geometry ?? keyDrag?.geometry ?? imageDrag?.geometry ?? dropGeometry ?? scrubGeometry ?? TimelineGeometry(time: currentTime, duration: duration, span: visibleSpan, width: max(1, bounds.width - Self.gutter))
    }
    static let gutter = 78.0
    private let clipY = 39.0
    private let clipHeight = 44.0
    private let trimHandleWidth = 8.0

    private struct ClipHit {
        let id: UUID
        let part: TimelineDragPart
        let trimArea: NSRect?
    }

    private var timeViewport: NSRect {
        NSRect(x: Self.gutter + TimelineGeometry.inset, y: 0,
               width: max(0, bounds.width - Self.gutter - 2 * TimelineGeometry.inset), height: bounds.height)
    }

    private var canHighlightTrim: Bool {
        isEnabled && drag == nil && imageDrag == nil && keyDrag == nil && scrubGeometry == nil &&
            dropGeometry == nil && automationPreview == nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                                       owner: self, userInfo: nil))
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
            let rect = lyricRect(clip)
            let visible = rect.intersection(timeViewport)
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
            for x in [rect.minX + 3, rect.maxX - 5] where x >= visible.minX && x + 2 <= visible.maxX {
                NSRect(x: x, y: clipY + 12, width: 2, height: 20).fill()
            }
        }
        let playhead = x(at: currentTime)
        if playhead >= 0 && playhead <= bounds.width {
            NSColor.systemPink.setStroke()
            let line = NSBezierPath(); line.lineWidth = 2
            line.move(to: NSPoint(x: playhead, y: 23)); line.line(to: NSPoint(x: playhead, y: 88)); line.stroke()
        }
        if canHighlightTrim, let point = hoverPoint {
            drawTrimHighlight(lyricHit(at: point))
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
    private func trimArea(in rect: NSRect, part: TimelineDragPart, viewport: NSRect) -> NSRect {
        let width = min(trimHandleWidth, rect.width / 2)
        let left = part == .start ? rect.minX : rect.maxX - width
        return NSRect(x: left, y: rect.minY, width: width, height: rect.height).intersection(viewport)
    }

    private func clipHit(id: UUID, at point: NSPoint, rect: NSRect, viewport: NSRect,
                         includingEdges: Bool = false) -> ClipHit? {
        let visible = rect.intersection(viewport)
        guard !visible.isEmpty else { return nil }
        if includingEdges {
            guard (visible.minX...visible.maxX).contains(point.x), (visible.minY...visible.maxY).contains(point.y) else { return nil }
        } else {
            guard visible.contains(point) else { return nil }
        }
        let left = point.x - rect.minX, right = rect.maxX - point.x
        guard min(left, right) <= trimHandleWidth else { return ClipHit(id: id, part: .move, trimArea: nil) }
        let part: TimelineDragPart = left <= right ? .start : .end
        return ClipHit(id: id, part: part, trimArea: trimArea(in: rect, part: part, viewport: viewport))
    }

    private func lyricRect(_ clip: LyricClip) -> NSRect {
        let left = x(at: clip.start)
        return NSRect(x: left, y: clipY, width: x(at: clip.end) - left, height: clipHeight)
    }

    private func lyricHit(at point: NSPoint) -> ClipHit? {
        for clip in track.clips {
            if let hit = clipHit(id: clip.id, at: point, rect: lyricRect(clip), viewport: timeViewport, includingEdges: true) {
                return hit
            }
        }
        return nil
    }

    private func imageHit(at point: NSPoint, slot: Int) -> ClipHit? {
        guard graphViewport.contains(point), let layer = images.layers.first(where: { $0.slot == slot }) else { return nil }
        for clip in layer.clips {
            if let hit = clipHit(id: clip.id, at: point, rect: imageRect(clip, slot: slot), viewport: graphViewport) {
                return hit
            }
        }
        return nil
    }

    private func drawTrimHighlight(_ hit: ClipHit?) {
        guard let area = hit?.trimArea, !area.isEmpty else { return }
        NSColor.systemYellow.setFill()
        area.fill()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        if isEnabled { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverPoint != nil {
            hoverPoint = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, window?.makeFirstResponder(self) != false else { return }
        mouseMoved(with: event)
        if imageMode {
            imageMouseDown(event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let frozen = geometry
        onBeginEdit?()
        if let hit = lyricHit(at: point) {
            selectedID = hit.id; onSelect?(hit.id)
            drag = Drag(original: track, geometry: frozen, id: hit.id, part: hit.part, initialX: point.x, draft: track)
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
        mouseMoved(with: event)
        if imageMode {
            imageMouseUp(event)
            return
        }
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
        if let value = keyDrag {
            keyDrag = nil
            if value.changed { restoreKeyPreview(value) }
        }
        dropGeometry = nil; dropCandidate = nil
        scrubGeometry = nil; needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelDrag() }
        else if event.keyCode == 51 || event.keyCode == 117, imageMode, isEnabled, expandedLayerSlots.contains(selectedSlot),
                keyDrag == nil, imageDrag == nil, let parameter = selectedParameter, let id = selectedKeyID,
                var clip = images.clip(selectedImageID), let slot = images.slot(of: clip.id) {
            do {
                clip.removeKey(id, parameter: parameter)
                let updated = try images.updating(clip, slot: slot, duration: duration)
                onBeginEdit?()
                onImageCommit?(updated, clip.id)
                selectGraph(clip.curve(parameter) == nil ? nil : parameter)
            } catch { onError?(error) }
        } else { super.keyDown(with: event) }
    }
    override func resetCursorRects() {
        guard isEnabled else { return }
        guard !imageMode else { return }
        for clip in track.clips {
            let rect = lyricRect(clip)
            let visible = rect.intersection(timeViewport)
            guard !visible.isEmpty else { continue }
            addCursorRect(visible, cursor: .openHand)
            for part in [TimelineDragPart.start, .end] {
                let handle = trimArea(in: rect, part: part, viewport: timeViewport)
                if !handle.isEmpty { addCursorRect(handle, cursor: .resizeLeftRight) }
            }
        }
    }

    private func automationParameters(in slot: Int) -> [ImageParameter] {
        guard expandedLayerSlots.contains(slot) else { return [] }
        return layerParameters[slot] ?? []
    }
    private func height(of slot: Int) -> Double {
        rowHeight + Double(automationParameters(in: slot).count) * graphHeight
    }
    private var contentHeight: Double { (1...3).reduce(0) { $0 + height(of: $1) } }
    private var rowsBottom: Double { min(bounds.height - 24, rowsTop + contentHeight - rowScroll) }
    private var maximumRowScroll: Double { max(0, rowsTop + contentHeight - (bounds.height - 24)) }

    func selectGraph(_ parameter: ImageParameter?, key: UUID? = nil, reveal: Bool = false) {
        selectedParameter = parameter
        selectedKeyID = key
        if reveal, let parameter, let slot = selectedImageID.flatMap({ images.slot(of: $0) }),
           let index = automationParameters(in: slot).firstIndex(of: parameter) {
            revealRows(from: graphY(slot: slot, index: index), height: graphHeight - 4)
        }
        onGraphSelection?()
        needsDisplay = true
    }

    func resetGraphDisclosure() {
        expandedLayerSlots.removeAll()
        rowScroll = 0
        updateGraphLayout()
    }

    func revealAutomation(in slot: Int) {
        setAutomationExpanded(true, in: slot)
    }

    private func setAutomationExpanded(_ expanded: Bool, in slot: Int) {
        cancelDrag()
        if expanded { expandedLayerSlots.insert(slot) }
        else { expandedLayerSlots.remove(slot) }
        updateGraphLayout()
        revealRows(from: rowY(slot), height: height(of: slot) > rowHeight ? rowHeight + graphHeight : rowHeight)
    }

    private func revealRows(from top: Double, height: Double) {
        if top + height > rowsBottom { rowScroll += top + height - rowsBottom }
        if top < rowsTop { rowScroll += top - rowsTop }
        rowScroll = min(maximumRowScroll, max(0, rowScroll))
        needsDisplay = true
    }

    private func updateGraphLayout() {
        rowScroll = min(maximumRowScroll, max(0, rowScroll))
        if let parameter = selectedParameter,
           let curve = images.clip(selectedImageID)?.curve(parameter) {
            if let key = selectedKeyID, !curve.keys.contains(where: { $0.id == key }) { selectGraph(parameter) }
        } else if selectedParameter != nil {
            selectGraph(nil)
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGraphLayout()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            guard isEnabled, drag == nil, keyDrag == nil, imageDrag == nil, scrubGeometry == nil,
                  dropGeometry == nil, event.momentumPhase.isEmpty else { return }
            let steps = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.deltaY
            if steps.isFinite, steps != 0 { onWheelZoom?(steps) }
            return
        }
        guard imageMode, maximumRowScroll > 0, keyDrag == nil, imageDrag == nil else { super.scrollWheel(with: event); return }
        rowScroll -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
        updateGraphLayout()
    }

    private func slot(at point: NSPoint) -> Int? {
        guard point.y >= rowsTop, point.y < rowsBottom else { return nil }
        return (1...3).first { slot in
            let y = rowY(slot)
            return point.y >= y && point.y < y + height(of: slot)
        }
    }

    private func rowY(_ slot: Int) -> Double {
        rowsTop - rowScroll + (1...3).filter { $0 > slot }.reduce(0) { $0 + height(of: $1) }
    }

    private func disclosureRect(for slot: Int) -> NSRect {
        NSRect(x: 55, y: rowY(slot) + 8, width: 22, height: 29)
    }

    private func graphY(slot: Int, index: Int) -> Double {
        rowY(slot) + rowHeight + Double(index) * graphHeight + 4
    }

    private func graphLanes(in displayed: ImageTrack) -> [GraphLane] {
        displayed.layers.flatMap { layer in
            let parameters = automationParameters(in: layer.slot)
            guard !parameters.isEmpty else { return [GraphLane]() }
            return layer.clips.filter { $0.end >= geometry.origin && $0.start <= geometry.origin + geometry.span }.flatMap { clip in
                parameters.enumerated().compactMap { index, parameter in
                    guard let curve = clip.curve(parameter) else { return nil }
                    let left = x(at: clip.start)
                    let rect = NSRect(x: left, y: graphY(slot: layer.slot, index: index),
                                      width: x(at: clip.end) - left, height: graphHeight - 8)
                    return GraphLane(clip: clip, curve: curve, rect: rect)
                }
            }
        }
    }
    private func imageRect(_ clip: ImageClip, slot: Int) -> NSRect {
        NSRect(x: x(at: clip.start), y: rowY(slot) + 3, width: x(at: clip.end) - x(at: clip.start), height: 39)
    }
    private var graphViewport: NSRect {
        NSRect(x: Self.gutter + TimelineGeometry.inset, y: rowsTop,
                                width: max(0, bounds.width - Self.gutter - 2 * TimelineGeometry.inset),
                                height: max(0, rowsBottom - rowsTop))
    }

    private func drawImages() {
        let clipBounds = graphViewport
        let displayed = keyDrag?.draft ?? imageDrag?.draft ?? automationPreview ?? images
        let interval = geometry.tickInterval
        var time = ceil(geometry.origin / interval) * interval
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: clipBounds.minX, y: 0, width: clipBounds.width, height: rowsTop)).addClip()
        while time <= min(duration, geometry.origin + geometry.span) + 1e-9 {
            label(TimelineGeometry.label(time), rect: NSRect(x: x(at: time) + 2, y: 4, width: 80, height: 16), color: .lightGray, size: 10)
            time += interval
        }
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: rowsTop, width: bounds.width, height: clipBounds.height)).addClip()
        let selectedClip = displayed.clip(selectedImageID)
        let selectedLayer = selectedImageID.flatMap { displayed.slot(of: $0) }
        for slot in 1...3 {
            if slot == (imageDrag?.targetSlot ?? selectedSlot) {
                NSColor.white.withAlphaComponent(0.04).setFill()
                NSRect(x: 0, y: rowY(slot), width: bounds.width, height: height(of: slot)).fill()
            }
            label("画像\(slot)" + (slot == 3 ? " 前" : slot == 1 ? " 後" : ""), rect: NSRect(x: 5, y: rowY(slot) + 14, width: 50, height: 18), color: .lightGray, size: 11)
            if layerParameters[slot]?.isEmpty == false {
                let button = disclosureRect(for: slot)
                label(expandedLayerSlots.contains(slot) ? "v" : ">",
                      rect: NSRect(x: button.minX + 6, y: button.minY + 6, width: 16, height: 18),
                      color: .white.withAlphaComponent(0.45), size: 12)
            }
            let clip = selectedLayer == slot ? selectedClip : nil
            for (index, parameter) in automationParameters(in: slot).enumerated() {
                let color: NSColor = clip != nil && parameter == selectedParameter ? .cyan : .lightGray
                let y = graphY(slot: slot, index: index)
                label(parameter.title, rect: NSRect(x: 5, y: y, width: 73, height: 16), color: color, size: 11)
                if let curve = clip?.curve(parameter) {
                    label("最大 " + Self.graphNumber(curve.maximum), rect: NSRect(x: 5, y: y + 17, width: 73, height: 14), color: color, size: 9)
                    label("最小 " + Self.graphNumber(curve.minimum), rect: NSRect(x: 5, y: y + 32, width: 73, height: 14), color: color, size: 9)
                }
            }
        }
        let lanes = graphLanes(in: displayed)
        NSBezierPath(rect: clipBounds).addClip()
        time = ceil(geometry.origin / interval) * interval
        while time <= min(duration, geometry.origin + geometry.span) + 1e-9 {
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x(at: time), y: rowsTop))
            line.line(to: NSPoint(x: x(at: time), y: rowsBottom))
            line.stroke()
            time += interval
        }
        for lyric in track.clips where lyric.end > geometry.origin && lyric.start < geometry.origin + geometry.span {
            let rect = NSRect(x: x(at: lyric.start), y: rowsTop, width: x(at: lyric.end) - x(at: lyric.start), height: clipBounds.height)
            NSColor.systemYellow.withAlphaComponent(0.10).setFill(); rect.fill()
            NSColor.systemYellow.withAlphaComponent(0.25).setStroke()
            let edge = NSBezierPath(); edge.setLineDash([3, 3], count: 2, phase: 0)
            for x in [rect.minX, rect.maxX] { edge.move(to: NSPoint(x: x, y: rowsTop)); edge.line(to: NSPoint(x: x, y: rowsBottom)) }; edge.stroke()
        }
        for layer in displayed.layers {
            for clip in layer.clips {
                let rect = imageRect(clip, slot: layer.slot).intersection(clipBounds)
                guard !rect.isEmpty else { continue }
                let missing = missingAssets.contains(clip.assetID)
                (missing ? NSColor.systemRed : NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.57, alpha: 1)).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 0), xRadius: 4, yRadius: 4).fill()
                if clip.id == selectedImageID { NSColor.cyan.setStroke(); NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).stroke() }
                label( (missing ? "⚠ " : "") + (displayed.asset(clip.assetID)?.name ?? "不明"), rect: NSRect(x: rect.minX + 8, y: rect.minY + 3, width: max(0, rect.width - 16), height: 17), color: .white, size: 11)
                label("\(TimelineGeometry.label(clip.start)) → \(TimelineGeometry.label(clip.end))", rect: NSRect(x: rect.minX + 8, y: rect.minY + 22, width: max(0, rect.width - 16), height: 13), color: .white, size: 9)
                NSColor.white.withAlphaComponent(0.6).setFill()
                for edge in [x(at: clip.start) + 3, x(at: clip.end) - 5] { NSRect(x: edge, y: rect.minY + 12, width: 2, height: 15).fill() }
            }
        }
        let highlight = highlightedKey(in: lanes)
        if highlight == nil, canHighlightTrim, let point = hoverPoint, let slot = slot(at: point) {
            drawTrimHighlight(imageHit(at: point, slot: slot))
        }
        for lane in lanes { drawGraph(lane, clippedTo: clipBounds, excluding: highlight?.key.id) }
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
        let head = NSBezierPath(); head.lineWidth = 2; head.move(to: NSPoint(x: x(at: currentTime), y: rowsTop)); head.line(to: NSPoint(x: x(at: currentTime), y: rowsBottom)); head.stroke()
        if let highlight {
            drawKey(highlight.key, in: highlight.lane, at: keyPosition(highlight.key, in: highlight.lane),
                    radius: highlightedKeyRadius, color: .systemYellow)
        }
        NSGraphicsContext.restoreGraphicsState()
        for lyric in track.clips where clipBounds.width > 0 {
            let left = max(clipBounds.minX, x(at: lyric.start))
            let right = min(clipBounds.maxX, x(at: lyric.end))
            label(lyric.text.replacingOccurrences(of: "\n", with: " "), rect: NSRect(x: left + 3, y: 27, width: right - left - 6, height: 16), color: .systemYellow.withAlphaComponent(0.4), size: 10)
        }
        let hint = contentHeight > rowHeight * 3 ? "グラフ：クリックで追加、ドラッグで調整、Deleteで削除　｜　上下スクロール　Esc：取消" : "本体：左右で時刻移動・上下で段移動　端：開始/終了　Esc：取消"
        label(imageDrag?.error ?? hint, rect: NSRect(x: 14, y: bounds.height - 19, width: bounds.width - 28, height: 16), color: .lightGray, size: 10)
    }
    private func imageMouseDown(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let frozen = geometry
        if graphMouseDown(at: point, geometry: frozen) { return }
        if let slot = slot(at: point) {
            if layerParameters[slot]?.isEmpty == false, disclosureRect(for: slot).contains(point) {
                setAutomationExpanded(!expandedLayerSlots.contains(slot), in: slot)
                return
            }
            selectedSlot = slot
            if let hit = imageHit(at: point, slot: slot) {
                selectedImageID = hit.id; onImageSelect?(hit.id, slot)
                onBeginEdit?()
                imageDrag = ImageDrag(original: images, geometry: frozen, id: hit.id, part: hit.part, initialX: point.x, draft: images, targetSlot: slot, error: nil)
                return
            }
            selectedImageID = nil; onImageSelect?(nil, slot)
        }
        guard point.x >= Self.gutter else { return }
        onBeginEdit?(); scrubGeometry = frozen; seek(at: point.x, geometry: frozen)
    }
    private func imageMouseDragged(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if keyDrag != nil { updateKeyDrag(to: point); return }
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
        if keyDrag != nil {
            finishKeyDrag(at: convert(event.locationInWindow, from: nil))
            return
        }
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
        guard imageMode, isEnabled, imageDrag == nil, keyDrag == nil, drag == nil else { return [] }
        dropGeometry = geometry
        return draggingUpdated(sender)
    }
    func fileDrop(at point: NSPoint, pasteboard: NSPasteboard) throws -> (url: URL, slot: Int, start: Double, end: Double) {
        guard imageMode, isEnabled, imageDrag == nil, keyDrag == nil, drag == nil, let url = droppedURL(pasteboard),
              point.x >= Self.gutter + TimelineGeometry.inset, point.x <= bounds.width - TimelineGeometry.inset,
              let slot = slot(at: point), point.y < rowY(slot) + rowHeight else { throw StudioError.message("画像を1枚ずつ、配置可能な画像行の空白にドロップしてください。") }
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

private extension TimelineView {
    private static func graphNumber(_ value: Double) -> String { String(format: "%.5g", value) }

    private func drawGraph(_ lane: GraphLane, clippedTo clipBounds: NSRect, excluding highlightedID: UUID?) {
        let visible = lane.rect.intersection(clipBounds)
        guard !visible.isEmpty else { return }
        let active = lane.clip.id == selectedImageID && lane.curve.parameter == selectedParameter
        let color: NSColor = active ? .systemCyan : .systemTeal
        color.withAlphaComponent(active ? 0.20 : 0.12).setFill()
        visible.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: visible.insetBy(dx: -keyMarkerRadius, dy: -keyMarkerRadius)).addClip()

        // Split segments at range crossings before drawing their visible, clamped portions.
        let first = max(0, geometry.time(at: visible.minX - Self.gutter) - lane.clip.start)
        let last = min(lane.clip.end - lane.clip.start, geometry.time(at: visible.maxX - Self.gutter) - lane.clip.start)
        let samples = [(first, lane.curve.value(at: first))] +
            lane.curve.keys.filter { first < $0.time && $0.time < last }.map { ($0.time, $0.value) } +
            [(last, lane.curve.value(at: last))]
        let path = NSBezierPath()
        func plot(_ time: Double, _ value: Double) {
            path.line(to: NSPoint(x: x(at: lane.clip.start + time), y: lane.y(at: value)))
        }
        path.move(to: NSPoint(x: visible.minX, y: lane.y(at: samples[0].1)))
        for (a, b) in zip(samples, samples.dropFirst()) {
            let limits = a.1 < b.1 ? [lane.curve.minimum, lane.curve.maximum] : [lane.curve.maximum, lane.curve.minimum]
            for limit in limits where min(a.1, b.1) < limit && limit < max(a.1, b.1) {
                let fraction = (limit / 2 - a.1 / 2) / (b.1 / 2 - a.1 / 2)
                plot(a.0 + (b.0 - a.0) * fraction, limit)
            }
            plot(b.0, b.1)
        }
        color.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        let markerBounds = visible.insetBy(dx: -keyMarkerRadius, dy: -keyMarkerRadius)
        for key in lane.curve.keys where key.id != highlightedID && lane.clip.containsKey(key) {
            let center = keyPosition(key, in: lane)
            guard markerBounds.contains(center) else { continue }
            let selected = active && key.id == selectedKeyID
            drawKey(key, in: lane, at: center, radius: keyMarkerRadius, color: selected ? .white : color)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func keyPosition(_ key: ImageKeyframe, in lane: GraphLane) -> NSPoint {
        NSPoint(x: x(at: lane.clip.start + key.time), y: lane.y(at: key.value))
    }

    private func drawKey(_ key: ImageKeyframe, in lane: GraphLane, at center: NSPoint, radius: Double, color: NSColor) {
        let marker = NSBezierPath()
        let top = key.value < lane.curve.minimum ? 0 : radius
        let bottom = key.value > lane.curve.maximum ? 0 : radius
        marker.move(to: NSPoint(x: center.x, y: center.y - top))
        marker.line(to: NSPoint(x: center.x + radius, y: center.y))
        marker.line(to: NSPoint(x: center.x, y: center.y + bottom))
        marker.line(to: NSPoint(x: center.x - radius, y: center.y))
        marker.close()
        color.setFill()
        marker.fill()
    }

    private func highlightedKey(in lanes: [GraphLane]) -> (lane: GraphLane, key: ImageKeyframe)? {
        guard isEnabled, imageDrag == nil, scrubGeometry == nil, dropGeometry == nil, automationPreview == nil else { return nil }
        if let drag = keyDrag {
            guard let keyID = drag.key?.id,
                  let lane = lanes.first(where: {
                      $0.clip.id == drag.lane.clip.id && $0.curve.parameter == drag.lane.curve.parameter
                  }),
                  let key = lane.curve.keys.first(where: { $0.id == keyID }) else { return nil }
            return (lane, key)
        }
        guard let point = hoverPoint else { return nil }
        return graphKey(at: point, in: lanes)
    }

    private func graphKey(at point: NSPoint, in lanes: [GraphLane]) -> (lane: GraphLane, key: ImageKeyframe)? {
        let viewport = graphViewport
        guard viewport.contains(point) else { return nil }
        let visibleCenters = viewport.insetBy(dx: -1, dy: -1)
        var hit: (lane: GraphLane, key: ImageKeyframe, distance: Double)?
        for lane in lanes where lane.rect.insetBy(dx: -keyHitRadius, dy: -keyHitRadius).contains(point) {
            for key in lane.curve.keys where lane.clip.containsKey(key) {
                let center = keyPosition(key, in: lane)
                guard visibleCenters.contains(center) else { continue }
                let distance = hypot(center.x - point.x, center.y - point.y)
                guard distance <= keyHitRadius else { continue }
                if let hit, hit.distance < distance || (hit.distance == distance && hit.lane.clip.id == selectedImageID) { continue }
                hit = (lane, key, distance)
            }
        }
        return hit.map { ($0.lane, $0.key) }
    }

    private func graphMouseDown(at point: NSPoint, geometry: TimelineGeometry) -> Bool {
        guard point.y >= rowsTop, point.y <= rowsBottom else { return false }
        if point.x < Self.gutter, let slot = slot(at: point), slot == selectedSlot,
           let clip = images.clip(selectedImageID),
           let match = automationParameters(in: slot).enumerated().first(where: { index, parameter in
               let y = graphY(slot: slot, index: index)
               return clip.curve(parameter) != nil && (y...(y + graphHeight - 8)).contains(point.y)
           }) {
            selectGraph(match.element, key: selectedParameter == match.element ? selectedKeyID : nil)
            let localY = point.y - graphY(slot: slot, index: match.offset)
            if localY >= 17 { onGraphRangeEdit?(localY < 32) }
            return true
        }
        guard graphViewport.contains(point) else { return false }
        let lanes = graphLanes(in: images)
        let hit = graphKey(at: point, in: lanes)
        guard let lane = hit?.lane ?? lanes.first(where: { $0.rect.contains(point) }),
              let slot = images.slot(of: lane.clip.id) else { return false }
        let key = hit?.key
        if selectedImageID != lane.clip.id {
            selectedSlot = slot
            selectedImageID = lane.clip.id
            onImageSelect?(lane.clip.id, slot)
        }
        onBeginEdit?()
        keyDrag = KeyDrag(original: images, geometry: geometry, lane: lane, key: key, initial: point, previousTime: currentTime)
        selectGraph(lane.curve.parameter, key: key?.id)
        if let key { onSeek?(lane.clip.start + key.time) }
        return true
    }

    private func updateKeyDrag(to point: NSPoint) {
        guard var drag = keyDrag, let key = drag.key,
              let slot = drag.original.slot(of: drag.lane.clip.id) else { return }
        var clip = drag.lane.clip
        var curve = drag.lane.curve
        let rawTime = clip.start + key.time + (point.x - drag.initial.x) / drag.geometry.pointsPerSecond
        let time = point.x == drag.initial.x ? clip.start + key.time : clip.keyTime(at: rawTime, grid: keySnapEnabled ? snapGrid : nil)
        let y = drag.lane.y(at: key.value) + point.y - drag.initial.y
        let value = point.y == drag.initial.y ? key.value : drag.lane.value(at: y)
        drag.changed = true
        do {
            try curve.move(id: key.id, to: time - clip.start, value: value)
            clip.setCurve(curve)
            drag.draft = try drag.original.updating(clip, slot: slot, duration: duration)
            onSeek?(time)
        } catch {
            drag.draft = nil
            onError?(error)
        }
        keyDrag = drag
        onImagePreview?(drag.draft ?? drag.original)
        needsDisplay = true
    }

    private func restoreKeyPreview(_ drag: KeyDrag) {
        onImagePreview?(drag.original)
        onSeek?(drag.previousTime)
    }

    private func finishKeyDrag(at point: NSPoint) {
        guard let original = keyDrag else { return }
        if original.key != nil, original.changed { updateKeyDrag(to: point) }
        guard let drag = keyDrag else { return }
        keyDrag = nil
        let parameter = drag.lane.curve.parameter
        if let key = drag.key {
            if let draft = drag.draft, draft != drag.original {
                onImageCommit?(draft, drag.lane.clip.id)
            } else if drag.changed {
                restoreKeyPreview(drag)
            }
            selectGraph(parameter, key: key.id)
        } else if hypot(point.x - drag.initial.x, point.y - drag.initial.y) <= 5 {
            var clip = drag.lane.clip
            let rawTime = drag.geometry.time(at: drag.initial.x - Self.gutter)
            let time = clip.keyTime(at: rawTime, grid: keySnapEnabled ? snapGrid : nil)
            if let key = drag.lane.curve.key(near: time - clip.start) {
                selectGraph(parameter, key: key.id)
                onSeek?(clip.start + key.time)
            } else if let slot = images.slot(of: clip.id) {
                let keyID = clip.setKey(parameter, at: time, value: drag.lane.value(at: drag.initial.y))
                do {
                    let updated = try images.updating(clip, slot: slot, duration: duration)
                    onImageCommit?(updated, clip.id)
                    selectGraph(parameter, key: keyID)
                } catch { onError?(error) }
            }
        }
        needsDisplay = true
    }
}
