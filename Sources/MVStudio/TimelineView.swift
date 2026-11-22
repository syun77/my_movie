import AppKit

@MainActor
final class TimelineView: NSView {
    var visualMode = false { didSet { hoverPoint = nil; cancelDrag(); updateGraphLayout(); setAccessibilityLabel(visualMode ? "画像タイムライン" : "歌詞タイムライン"); needsDisplay = true } }
    var visuals = VisualTrack() {
        didSet {
            if visuals.layer(selectedLayerID) == nil, let id = visuals.layers.first?.id { selectedLayerID = id }
            rebuildLayerParameters()
            updateGraphLayout()
        }
    }
    var audioFeatures: AudioFeatures? { didSet { needsDisplay = true } }
    var sceneSettings = SceneSettings() { didSet { needsDisplay = true } }
    var automationPreview: VisualTrack? { didSet { needsDisplay = true } }
    var missingAssets = Set<UUID>() { didSet { needsDisplay = true } }
    var selectedImageID: UUID? {
        didSet {
            if oldValue != selectedImageID { selectGraph(nil); spineLane.clearSelection() }
            rebuildLayerParameters()
            updateGraphLayout()
        }
    }
    private(set) var expandedLayerIDs: Set<UUID> = []
    private var layerParameters: [UUID: [ImageParameter]] = [:]
    private(set) var selectedParameter: ImageParameter?
    private(set) var selectedKeyID: UUID?
    var onGraphSelection: (() -> Void)?
    var onGraphRangeEdit: ((Bool) -> Void)?
    var onWheelZoom: ((Double) -> Void)?
    var keySnapEnabled = true
    var heights = TimelineHeights() { didSet { updateRowLayout() } }
    var onHeightCommit: (() -> Void)?
    private let spineLane = SpineTimelineLane()
    var onSpineLaneAction: ((SpineLaneAction) -> Void)?
    private var imageScroll = 0.0
    private var lyricScroll = 0.0
    private var rowScroll: Double {
        get { visualMode ? imageScroll : lyricScroll }
        set {
            if visualMode { imageScroll = newValue }
            else { lyricScroll = newValue }
        }
    }
    private let rowsTop = 48.0
    private var rowResize: RowResize?
    private struct LayoutRow { let row: TimelineHeights.Row; let top: Double; let height: Double }
    private var layoutRows: [LayoutRow] = []
    private var layerOffsets: [UUID: Double] = [:]
    private var layoutHeight = 0.0

    private struct RowResize {
        let row: TimelineHeights.Row
        let initialY: Double
        let initialHeight: Double
        let initialScroll: Double
        var height: Double
    }

    private struct RowBoundary {
        let row: TimelineHeights.Row
        let y: Double
    }
    private var keyDrag: KeyDrag?
    private var hoverPoint: NSPoint?
    private var defaultToolTip: String?
    private let graphPadding = 4.0
    private let keyHitRadius = 11.0
    private let keyMarkerRadius = 4.0
    private let highlightedKeyRadius = 6.0

    private struct KeyDrag {
        let original: VisualTrack
        let geometry: TimelineGeometry
        let lane: GraphLane
        let key: ImageKeyframe?
        let bendKeyID: UUID?
        let initial: NSPoint
        let previousTime: Double
        var draft: VisualTrack?
        var changed = false
    }

    private struct GraphLane {
        let clip: VisualClip
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
    var selectedLayerID = UUID() { didSet { needsDisplay = true } }
    var onImageSelect: ((UUID?, UUID) -> Void)?
    var onImagePreview: ((VisualTrack) -> Void)?
    var onImageCommit: ((VisualTrack, UUID) -> Void)?
    var onCreateEmptyClip: ((UUID, Double) -> Void)?
    var onDropImage: ((URL, UUID, Double) -> Void)?
    private var imageDrag: ImageDrag?
    private var dropGeometry: TimelineGeometry?
    private var dropCandidate: (layerID: UUID, start: Double, end: Double)?
    private struct ImageDrag {
        let original: VisualTrack
        let geometry: TimelineGeometry
        let id: UUID
        let part: TimelineDragPart
        let initialX: Double
        var draft: VisualTrack
        var hasDragged = false
        var targetLayerID: UUID?
        var error: String?
    }
    var snapGrid = TimelineSnapGrid() { didSet { cancelDrag(); needsDisplay = true } }
    var track = LyricsTrack() { didSet { needsDisplay = true } }
    var currentTime = 0.0 { didSet { needsDisplay = true } }
    var duration = 0.0 { didSet { followPlayhead(); needsDisplay = true } }
    var visibleSpan = TimelineDisplaySettings.defaultSpan { didSet { needsDisplay = true } }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var isEnabled = false { didSet { if !isEnabled { cancelDrag() }; needsDisplay = true } }
    var canPerformClipCommand: ((ClipEditCommand) -> Bool)?
    var onCreateLyricClip: ((Double) -> Void)?
    var onClipCommand: ((ClipEditCommand) -> Void)?
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
    private var manualOrigin: Double? {
        didSet {
            guard oldValue != manualOrigin else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var geometry: TimelineGeometry {
        frozenGeometry ?? TimelineGeometry(time: currentTime, duration: duration, span: visibleSpan,
                                           width: bounds.width - Self.gutter, manualOrigin: manualOrigin)
    }
    private var frozenGeometry: TimelineGeometry? {
        spineLane.frozenGeometry ?? drag?.geometry ?? keyDrag?.geometry ?? imageDrag?.geometry ?? dropGeometry ?? scrubGeometry
    }

    func followPlayhead() { manualOrigin = nil }

    static let gutter = 220.0
    private var clipY: Double { 39 - lyricScroll }
    private var clipHeight: Double { rowHeight(.lyrics) }
    private var lyricBoundaryY: Double { clipY + clipHeight + 4 }
    private var lyricViewport: NSRect {
        NSRect(x: timeViewport.minX, y: 24, width: timeViewport.width, height: max(0, bounds.height - 48))
    }
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

    var canEditClips: Bool {
        isEnabled && layerDrag == nil && rowResize == nil && frozenGeometry == nil && automationPreview == nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                                       owner: self, userInfo: nil))
        spineLane.onCommit = { [weak self] in self?.onImageCommit?($0, $1) }
        spineLane.onPreview = { [weak self] in self?.onImagePreview?($0) }
        spineLane.onBegin = { [weak self] in self?.onBeginEdit?() }
        spineLane.onSelect = { [weak self] in self?.selectGraph(nil) }
        spineLane.onError = { [weak self] in self?.onError?($0) }
        spineLane.onAction = { [weak self] in self?.onSpineLaneAction?($0) }
        spineLane.onDisplay = { [weak self] in self?.needsDisplay = true }
        identifier = NSUserInterfaceItemIdentifier("placement.timeline")
        toolTip = "Shift＋ホイールで横スクロール、⌘＋ホイールで拡大・縮小、Option＋ホイールで再生位置を移動。本体を左右で時刻移動、画像本体を上下でレイヤー移動。左右端で開始・終了を調整。行の下の境界線で高さを調整。空白や目盛りでシーク。Escで取り消し。"
        defaultToolTip = toolTip
        updateRowLayout()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("歌詞タイムライン")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 1).setFill(); bounds.fill()
        if visualMode {
            drawImages()
            label("＋ レイヤー", rect: addLayerRect, color: isEnabled ? .white : .gray, size: 11)
        }
        else { drawLyrics() }
        drawRowBoundaries()
        drawLayerDragPresentation()
    }

    private func drawLyrics() {
        let geometry = geometry
        let displayed = drag?.draft ?? track
        let interval = geometry.tickInterval
        var time = ceil(geometry.origin / interval) * interval
        while time <= min(duration, geometry.origin + geometry.span) + 1e-9 {
            let x = x(at: time)
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: 24)); line.line(to: NSPoint(x: x, y: min(lyricBoundaryY, lyricViewport.maxY))); line.stroke()
            label(TimelineGeometry.label(time), rect: NSRect(x: x + 3, y: 6, width: 78, height: 15), color: .lightGray, size: 10)
            time += interval
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: lyricViewport).addClip()
        for clip in displayed.clips where clip.end > geometry.origin && clip.start < geometry.origin + geometry.span {
            let rect = lyricRect(clip)
            let visible = rect.intersection(lyricViewport)
            guard !visible.isEmpty else { continue }
            let selected = clip.id == selectedID
            NSColor(calibratedRed: selected ? 0.14 : 0.12, green: selected ? 0.55 : 0.32, blue: selected ? 0.68 : 0.43, alpha: 1).setFill()
            NSBezierPath(roundedRect: visible.insetBy(dx: 1, dy: 0), xRadius: 4, yRadius: 4).fill()
            if selected {
                NSColor.cyan.setStroke()
                NSBezierPath(roundedRect: visible.insetBy(dx: 1, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
            }
            let text = (clip.predecessorID == nil ? "" : "↳ ") + clip.text.replacingOccurrences(of: "\n", with: " / ")
            drawClipLabels(text, timing: clipTiming(start: clip.start, end: clip.end), in: rect, visible: visible)
            drawClipGrips(in: rect, visible: visible)
        }
        NSGraphicsContext.restoreGraphicsState()
        let playhead = x(at: currentTime)
        if playhead >= timeViewport.minX && playhead <= timeViewport.maxX {
            NSColor.systemPink.setStroke()
            let line = NSBezierPath(); line.lineWidth = 2
            line.move(to: NSPoint(x: playhead, y: 23)); line.line(to: NSPoint(x: playhead, y: min(lyricBoundaryY + 1, lyricViewport.maxY))); line.stroke()
        }
        if canEditClips, let point = hoverPoint {
            drawTrimHighlight(lyricHit(at: point))
        }
        let footer = duration > 0 ? "再生位置 \(TimelineGeometry.label(currentTime))　｜　本体：移動　端：開始/終了　Esc：取消" : "音声を読み込むと、再生位置の周辺と歌詞の表示区間を確認できます"
        label(footer, rect: NSRect(x: 14, y: min(lyricBoundaryY + 5, bounds.height - 20), width: bounds.width - 28, height: 16), color: .lightGray, size: 10)
    }

    func x(at time: Double) -> Double { Self.gutter + geometry.x(at: time) }

    private func label(_ text: String, rect: NSRect, color: NSColor, size: CGFloat) {
        guard rect.width > 0 else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    private func clipTiming(start: Double, end: Double) -> String {
        "\(TimelineGeometry.label(start)) → \(TimelineGeometry.label(end))"
    }

    private func drawClipLabels(_ title: String, timing: String, in rect: NSRect, visible: NSRect) {
        let showsTiming = rect.height >= 35
        let titleHeight = min(rect.height, 17)
        let titleY = showsTiming ? rect.minY + 3 : rect.midY - titleHeight / 2
        let textX = visible.minX + 8
        let textWidth = visible.width - 16
        label(title, rect: NSRect(x: textX, y: titleY, width: textWidth, height: titleHeight),
              color: .white, size: rect.height < 17 ? 10 : 11)
        if showsTiming {
            label(timing, rect: NSRect(x: textX, y: rect.minY + 22, width: textWidth, height: 13),
                  color: .white.withAlphaComponent(0.8), size: 9)
        }
    }

    private func drawClipGrips(in rect: NSRect, visible: NSRect) {
        let height = min(20, rect.height - 6)
        NSColor.white.withAlphaComponent(0.6).setFill()
        for x in [rect.minX + 3, rect.maxX - 5] where x >= visible.minX && x + 2 <= visible.maxX {
            NSRect(x: x, y: rect.midY - height / 2, width: 2, height: height).fill()
        }
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
            if let hit = clipHit(id: clip.id, at: point, rect: lyricRect(clip), viewport: lyricViewport, includingEdges: true) {
                return hit
            }
        }
        return nil
    }

    private func imageHit(at point: NSPoint, layerID: UUID) -> ClipHit? {
        guard graphViewport.contains(point), let layer = visuals.layers.first(where: { $0.id == layerID }) else { return nil }
        let hits = layer.clips.compactMap { clip -> ClipHit? in
            clipHit(id: clip.id, at: point, rect: imageRect(clip, layerID: layerID), viewport: graphViewport)
        }
        let trims = hits.filter { $0.part != .move }.sorted { a, b in
            if (a.id == selectedImageID) != (b.id == selectedImageID) { return a.id == selectedImageID }
            @MainActor func distance(_ hit: ClipHit) -> CGFloat {
                guard let clip = layer.clips.first(where: { $0.id == hit.id }) else { return .infinity }
                return abs(point.x - x(at: hit.part == .start ? clip.start : clip.end))
            }
            if distance(a) != distance(b) { return distance(a) < distance(b) }
            return a.part == .start && b.part != .start
        }
        if let trim = trims.first { return trim }
        if let transition = crossfade(at: point, layer: layer) {
            let midpoint = x(at: (transition.start + transition.end) / 2)
            let id = point.x < midpoint ? transition.outgoingID : transition.incomingID
            return hits.first { $0.id == id }
        }
        return hits.first
    }

    private func crossfade(at point: NSPoint, layer: VisualLayer) -> LayerCrossfade? {
        LayerCrossfade.transitions(in: layer.clips).first { transition in
            guard let clip = layer.clips.first(where: { $0.id == transition.outgoingID }) else { return false }
            let rect = imageRect(clip, layerID: layer.id)
            return point.x >= x(at: transition.start) && point.x < x(at: transition.end)
                && point.y >= rect.minY && point.y < rect.maxY
        }
    }

    private func drawCrossfades(_ layer: VisualLayer) {
        for transition in LayerCrossfade.transitions(in: layer.clips) {
            guard let clip = layer.clips.first(where: { $0.id == transition.outgoingID }) else { continue }
            let row = imageRect(clip, layerID: layer.id)
            let left = x(at: transition.start), right = x(at: transition.end)
            let rect = NSRect(x: left, y: row.minY, width: right - left, height: row.height)
            let visible = rect.intersection(graphViewport)
            guard !visible.isEmpty else { continue }
            NSColor.black.withAlphaComponent(0.18).setFill(); visible.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: visible).addClip()
            let steps = max(2, Int(ceil(visible.width / 2)))
            for incoming in [false, true] {
                let path = NSBezierPath(); path.lineWidth = 1.5
                for index in 0...steps {
                    let px = visible.minX + visible.width * CGFloat(index) / CGFloat(steps)
                    let t = transition.start + Double((px - left) / (right - left)) * transition.duration
                    let f = transition.incomingWeight(at: t)
                    let value = incoming ? f : 1 - f
                    let point = NSPoint(x: px, y: row.minY + 3 + (row.height - 6) * (1 - value))
                    if index == 0 { path.move(to: point) } else { path.line(to: point) }
                }
                NSColor.white.withAlphaComponent(layer.isVisible ? 0.9 : 0.4).setStroke(); path.stroke()
            }
            NSColor.white.withAlphaComponent(0.5).setStroke()
            for px in [left, right] {
                let line = NSBezierPath(); line.move(to: NSPoint(x: px, y: row.minY)); line.line(to: NSPoint(x: px, y: row.maxY)); line.stroke()
            }
            if visible.width < 3 {
                NSColor.white.setFill(); NSRect(x: visible.midX - 0.5, y: row.minY + 2, width: 1, height: row.height - 4).fill()
            }
            if rect.width >= 155 && row.height >= 54 {
                label(String(format: "クロスフェード %.2f秒", transition.duration),
                      rect: NSRect(x: left + 5, y: row.maxY - 15, width: rect.width - 10, height: 13), color: .white, size: 9)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawTrimHighlight(_ hit: ClipHit?) {
        guard let area = hit?.trimArea, !area.isEmpty else { return }
        NSColor.systemYellow.setFill()
        area.fill()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        spineLane.mouseMoved(hoverPoint)
        toolTip = hoverPoint.flatMap { point in
            if point.x < Self.gutter, let id = layerID(at: point), let layer = visuals.layer(id) {
                let target = visuals.layers.firstIndex(where: { $0.id == id }).flatMap { $0 > 0 ? visuals.layers[$0 - 1].name : nil } ?? "なし"
                return layer.name + " / 直下段マスク対象: " + target
            }
            if visualMode, graphViewport.contains(point), let id = layerID(at: point), let layer = visuals.layer(id),
               let transition = crossfade(at: point, layer: layer) {
                @MainActor func name(_ id: UUID) -> String { visuals.asset(visuals.clip(id)?.assetID)?.name ?? "空のクリップ" }
                return name(transition.outgoingID) + " → " + name(transition.incomingID)
                    + String(format: " / クロスフェード %.6f秒", transition.duration)
            }
            return spineLane.tooltip(at: point)
        } ?? defaultToolTip
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if hoverPoint != nil {
            hoverPoint = nil
            spineLane.mouseMoved(nil)
            toolTip = defaultToolTip
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if visualMode, canEditClips, layerHeaderDown(event, point: point) { return }
        if frozenGeometry == nil, automationPreview == nil, let boundary = rowBoundary(at: point),
           window?.makeFirstResponder(self) != false {
            let height = rowHeight(boundary.row)
            rowResize = RowResize(row: boundary.row, initialY: point.y, initialHeight: height,
                                  initialScroll: rowScroll, height: height)
            hoverPoint = point
            NSCursor.resizeUpDown.set()
            needsDisplay = true
            return
        }
        guard isEnabled, window?.makeFirstResponder(self) != false else { return }
        mouseMoved(with: event)
        if visualMode {
            imageMouseDown(event)
            return
        }
        if event.clickCount == 2, let time = lyricCreationTime(at: point) {
            onCreateLyricClip?(time)
            return
        }
        let frozen = geometry
        onBeginEdit?()
        if let hit = lyricHit(at: point) {
            selectLyricClip(hit.id)
            drag = Drag(original: track, geometry: frozen, id: hit.id, part: hit.part, initialX: point.x, draft: track)
        } else {
            scrubGeometry = frozen
            seek(at: point.x, geometry: frozen)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if layerDrag != nil { updateLayerDrag(convert(event.locationInWindow, from: nil)); return }
        if rowResize != nil {
            updateRowResize(with: event)
            return
        }
        guard isEnabled else { return }
        if visualMode { imageMouseDragged(event); return }
        let point = convert(event.locationInWindow, from: nil)
        if var value = drag {
            do {
                value.draft = try value.original.dragging(id: value.id, part: value.part, delta: (point.x - value.initialX) / value.geometry.pointsPerSecond, duration: duration, grid: snapGrid)
                drag = value; onPreview?(value.draft); needsDisplay = true
            } catch { onError?(error) }
        } else if let frozen = scrubGeometry { seek(at: point.x, geometry: frozen) }
    }
    override func mouseUp(with event: NSEvent) {
        if layerDrag != nil { finishLayerDrag(convert(event.locationInWindow, from: nil)); return }
        if rowResize != nil {
            updateRowResize(with: event)
            if let resize = rowResize {
                rowResize = nil
                if heights.height(resize.row, nodeID: heightNodeID(resize.row)) != resize.height {
                    heights.setHeight(resize.height, for: resize.row, nodeID: heightNodeID(resize.row))
                    onHeightCommit?()
                } else {
                    needsDisplay = true
                }
            }
            return
        }
        guard isEnabled else { return }
        mouseMoved(with: event)
        if visualMode {
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
        if let value = layerDrag {
            layerDrag = nil; layerScrollTimer?.invalidate(); layerScrollTimer = nil
            visuals = value.original; onLayerPreview?(value.original); onImagePreview?(value.original); NSCursor.arrow.set()
        }
        spineLane.cancel()
        if let resize = rowResize {
            rowResize = nil
            if case .lyrics = resize.row { lyricScroll = resize.initialScroll }
            else { imageScroll = resize.initialScroll }
            updateRowLayout()
        }
        if let value = drag { drag = nil; onPreview?(value.original) }
        if let value = imageDrag { imageDrag = nil; NSCursor.arrow.set(); onImagePreview?(value.original) }
        if let value = keyDrag {
            keyDrag = nil
            if value.changed { restoreKeyPreview(value) }
        }
        dropGeometry = nil; dropCandidate = nil
        scrubGeometry = nil; needsDisplay = true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard canEditClips else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        if let time = lyricCreationTime(at: point), window?.makeFirstResponder(self) != false {
            let menu = NSMenu()
            let item = menu.addItem(withTitle: "歌詞クリップを追加", action: #selector(createLyricClip(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = time
            return menu
        }
        if visualMode, point.x < Self.gutter, let id = layerID(at: point), headerRect(id).contains(point) { return layerMenu(id) }
        if visualMode, onCreateEmptyClip != nil, point.x >= Self.gutter,
           point.x <= bounds.width - TimelineGeometry.inset, let layerID = layerID(at: point),
           let layer = visuals.layers.first(where: { $0.id == layerID }) {
            let time = geometry.time(at: point.x - Self.gutter)
            if !layer.clips.contains(where: { $0.start <= time && time < $0.end }),
               (try? visuals.placement(at: time, layerID: layerID, duration: duration, grid: snapGrid)) != nil {
                let menu = NSMenu()
                let item = menu.addItem(withTitle: "空のクリップを作成", action: #selector(createEmptyClip(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = EmptyClipTarget(layerID: layerID, time: time)
                return menu
            }
        }
        configureSpineLane(displayed: visuals)
        if visualMode, visuals.canEdit(selectedLayerID), let menu = spineLane.menu(at: point) { return menu }
        if visualMode, onImageCommit != nil,
           let hit = graphKey(at: point, in: graphLanes(in: visuals)),
           visuals.canEdit(visuals.layerID(of: hit.lane.clip.id)), window?.makeFirstResponder(self) != false {
            if selectedImageID != hit.lane.clip.id {
                selectedLayerID = visuals.layerID(of: hit.lane.clip.id) ?? selectedLayerID
                selectedImageID = hit.lane.clip.id
                onImageSelect?(hit.lane.clip.id, selectedLayerID)
            }
            selectGraph(hit.lane.curve.parameter, key: hit.key.id)
            let menu = NSMenu()
            menu.autoenablesItems = false
            let target = KeyMenuTarget(clipID: hit.lane.clip.id, parameter: hit.lane.curve.parameter, keyID: hit.key.id)
            let delete = menu.addItem(withTitle: "削除", action: #selector(deleteGraphKey(_:)), keyEquivalent: "")
            delete.target = self; delete.representedObject = target
            menu.addItem(.separator())
            for interpolation in ImageInterpolation.allCases {
                let item = menu.addItem(withTitle: interpolation.title, action: #selector(changeInterpolation(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = KeyInterpolationTarget(key: target, interpolation: interpolation)
                item.state = hit.key.incomingInterpolation == interpolation ? .on : .off
            }
            return menu
        }
        if canRemoveAutomation, let target = graphLabel(at: point)?.target ?? graphLanes(in: visuals).first(where: { $0.rect.contains(point) }).map({ GraphTarget(clipID: $0.clip.id, parameter: $0.curve.parameter) }), visuals.canEdit(visuals.layerID(of: target.clipID)) {
            let menu = NSMenu()
            let item = menu.addItem(withTitle: "レーンを削除（キー・LFO・音楽同期）", action: #selector(removeAutomationLane(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target
            for (title, tag) in [("キーモード", 0), ("LFOモード", 1), ("LFO設定を初期化", 2)] {
                let action = menu.addItem(withTitle: title, action: #selector(changeAutomationMode(_:)), keyEquivalent: "")
                action.target = self; action.representedObject = target; action.tag = tag
                if tag < 2 { action.state = (visuals.clip(target.clipID)?.activeLFO(target.parameter) != nil) == (tag == 1) ? .on : .off }
            }
            return menu
        }
        guard canPerformClipCommand != nil, selectClipForMenu(at: point) else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for command in ClipEditCommand.allCases {
            if command == .delete { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: command.title, action: #selector(performClipCommand(_:)),
                                    keyEquivalent: command == .delete ? "" : command.rawValue)
            item.target = self
            item.representedObject = command
            item.isEnabled = canPerformClipCommand?(command) == true
        }
        return menu
    }

    private func lyricCreationTime(at point: NSPoint) -> Double? {
        guard !visualMode, canEditClips, onCreateLyricClip != nil,
              lyricViewport.contains(point), rowBoundary(at: point) == nil,
              lyricHit(at: point) == nil else { return nil }
        let time = geometry.time(at: point.x - Self.gutter)
        guard time >= 0, time < duration,
              !track.clips.contains(where: { $0.start <= time && time < $0.end }),
              (try? track.adding(at: time, duration: duration, grid: snapGrid)) != nil else { return nil }
        return time
    }

    @objc private func createLyricClip(_ item: NSMenuItem) {
        guard !visualMode, canEditClips, let time = item.representedObject as? Double,
              !track.clips.contains(where: { $0.start <= time && time < $0.end }) else { return }
        onCreateLyricClip?(time)
    }

    private struct EmptyClipTarget {
        let layerID: UUID
        let time: Double
    }

    @objc private func createEmptyClip(_ item: NSMenuItem) {
        guard canEditClips, let target = item.representedObject as? EmptyClipTarget else { return }
        onCreateEmptyClip?(target.layerID, target.time)
    }

    private struct KeyMenuTarget {
        let clipID: UUID
        let parameter: ImageParameter
        let keyID: UUID
    }

    private struct KeyInterpolationTarget {
        let key: KeyMenuTarget
        let interpolation: ImageInterpolation
    }

    private func editGraphKey(_ target: KeyMenuTarget, delete: Bool = false, interpolation: ImageInterpolation = .single) {
        guard visualMode, canEditClips, let layerID = visuals.layerID(of: target.clipID),
              visuals.canEdit(layerID), var clip = visuals.clip(target.clipID), var curve = clip.curve(target.parameter),
              let index = curve.keys.firstIndex(where: { $0.id == target.keyID }) else { return }
        if delete { clip.removeKey(target.keyID, parameter: target.parameter) }
        else {
            guard curve.keys[index].incomingInterpolation != interpolation else { return }
            curve.keys[index].interpolation = interpolation == .single ? nil : interpolation
            clip.setCurve(curve)
        }
        do {
            let updated = try visuals.updating(clip, layerID: layerID, duration: duration)
            onBeginEdit?()
            onImageCommit?(updated, clip.id)
            selectGraph(clip.displayCurve(target.parameter) == nil ? nil : target.parameter, key: delete ? nil : target.keyID)
        } catch { onError?(error) }
    }

    @objc private func deleteGraphKey(_ item: NSMenuItem) {
        if let target = item.representedObject as? KeyMenuTarget { editGraphKey(target, delete: true) }
    }

    @objc private func changeInterpolation(_ item: NSMenuItem) {
        if let target = item.representedObject as? KeyInterpolationTarget {
            editGraphKey(target.key, interpolation: target.interpolation)
        }
    }

    private func selectClipForMenu(at point: NSPoint) -> Bool {
        if visualMode {
            guard let layerID = layerID(at: point), let hit = imageHit(at: point, layerID: layerID),
                  window?.makeFirstResponder(self) != false else { return false }
            selectVisualClip(hit.id, layerID: layerID)
        } else {
            guard let hit = lyricHit(at: point), window?.makeFirstResponder(self) != false else { return false }
            selectLyricClip(hit.id)
        }
        return true
    }

    private func selectLyricClip(_ id: UUID) {
        selectedID = id
        onSelect?(id)
    }

    private func selectVisualClip(_ id: UUID, layerID: UUID) {
        selectedLayerID = layerID
        selectedImageID = id
        spineLane.clearSelection()
        if selectedKeyID != nil { selectGraph(selectedParameter) }
        onImageSelect?(id, layerID)
    }

    @objc private func performClipCommand(_ item: NSMenuItem) {
        guard let command = item.representedObject as? ClipEditCommand,
              canPerformClipCommand?(command) == true else { return }
        onClipCommand?(command)
    }

    private var canRemoveAutomation: Bool {
        visualMode && canEditClips && visuals.canEdit(selectedLayerID) && onImageCommit != nil
    }

    @objc private func changeAutomationMode(_ item: NSMenuItem) {
        guard canRemoveAutomation, let target = item.representedObject as? GraphTarget,
              let layerID = visuals.layerID(of: target.clipID), visuals.canEdit(layerID),
              var clip = visuals.clip(target.clipID) else { return }
        clip.setAutomationMode(item.tag == 0 ? .keys : .lfo, for: target.parameter)
        if item.tag == 2 {
            var automation = clip.automation(target.parameter)!
            automation.lfo = LFOSettings(); clip.setAutomation(automation)
        }
        do {
            let updated = try visuals.updating(clip, layerID: layerID, duration: duration)
            onBeginEdit?(); onImageCommit?(updated, clip.id)
            selectedImageID = clip.id; selectedLayerID = layerID
            onImageSelect?(clip.id, layerID); selectGraph(target.parameter)
        } catch { onError?(error) }
    }

    @objc private func removeAutomationLane(_ item: NSMenuItem) {
        guard canRemoveAutomation, let target = item.representedObject as? GraphTarget,
              var clip = visuals.clip(target.clipID), clip.displayCurve(target.parameter) != nil,
              let layerID = visuals.layerID(of: clip.id) else { return }
        clip.removeAudioAndKeys(target.parameter)
        do {
            let updated = try visuals.updating(clip, layerID: layerID, duration: duration)
            onBeginEdit?()
            onImageCommit?(updated, clip.id)
        } catch { onError?(error) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelDrag(); return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117, canEditClips else {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat else { return }
        if removeSelectedKey() { return }
        if canPerformClipCommand?(.delete) == true { onClipCommand?(.delete) }
        else { super.keyDown(with: event) }
    }

    private func removeSelectedKey() -> Bool {
        if visualMode, !visuals.canEdit(selectedLayerID) { return selectedKeyID != nil || spineLane.selectedKeyID != nil }
        if visualMode, spineClip(in: selectedLayerID) != nil, spineLane.removeSelectedKey() { return true }
        guard visualMode, expandedLayerIDs.contains(selectedLayerID), let parameter = selectedParameter,
              let id = selectedKeyID, let clip = visuals.clip(selectedImageID) else { return false }
        editGraphKey(KeyMenuTarget(clipID: clip.id, parameter: parameter, keyID: id), delete: true)
        return true
    }

    override func resetCursorRects() {
        if isEnabled && !visualMode {
            for clip in track.clips {
                let rect = lyricRect(clip)
                let visible = rect.intersection(lyricViewport)
                guard !visible.isEmpty else { continue }
                addCursorRect(visible, cursor: .openHand)
                for part in [TimelineDragPart.start, .end] {
                    let handle = trimArea(in: rect, part: part, viewport: lyricViewport)
                    if !handle.isEmpty { addCursorRect(handle, cursor: .resizeLeftRight) }
                }
            }
        }
        for boundary in rowBoundaries {
            let rect = boundaryHitRect(boundary)
            if !rect.isEmpty { addCursorRect(rect, cursor: .resizeUpDown) }
        }
    }

    private func rebuildLayerParameters() {
            layerParameters = Dictionary(uniqueKeysWithValues: visuals.layers.map { layer in
                var seen = Set<ImageParameter>()
                let clips = layer.clips.sorted { ($0.id == selectedImageID ? 0 : 1) < ($1.id == selectedImageID ? 0 : 1) }
                return (layer.id, clips.flatMap(\.orderedAutomationParameters).filter { seen.insert($0).inserted })
            })
    }

    private func automationParameters(in layerID: UUID) -> [ImageParameter] {
        guard expandedLayerIDs.contains(layerID) else { return [] }
        return layerParameters[layerID] ?? []
    }

    private func hasAutomation(in layerID: UUID) -> Bool {
        layerParameters[layerID]?.isEmpty == false || visuals.layers.first(where: { $0.id == layerID })?.clips.contains(where: { $0.content.spinePlayback?.hasLane == true }) == true
    }
    private func spineClip(in layerID: UUID) -> VisualClip? {
        guard expandedLayerIDs.contains(layerID), let id = selectedImageID, visuals.layerID(of: id) == layerID,
              let clip = visuals.clip(selectedImageID), clip.content.spinePlayback?.hasLane == true else { return nil }
        return clip
    }
    private func spineMinimumHeight(_ layerID: UUID) -> Double {
        guard let clip = spineClip(in: layerID), let descriptor = visuals.asset(clip.assetID)?.kind.spineDescriptor else { return 80 }
        if case .selection = clip.content.spinePlayback?.mode { return max(80, Double(descriptor.animations.count) * 18 + 16) }
        return 80
    }
    private func spineHeight(_ layerID: UUID) -> Double { spineClip(in: layerID) == nil ? 0 : rowHeight(.spine(layerID)) }
    private func spineY(_ layerID: UUID) -> Double {
        automationParameters(in: layerID).reduce(rowY(layerID) + rowHeight(.visual(layerID))) { $0 + rowHeight(.automation(layerID, $1)) }
    }
    private func configureSpineLane(displayed: VisualTrack) {
        guard visualMode, let clip = displayed.clip(selectedImageID), let layerID = displayed.layerID(of: clip.id),
              expandedLayerIDs.contains(layerID), clip.content.spinePlayback?.hasLane == true,
              let descriptor = displayed.asset(clip.assetID)?.kind.spineDescriptor else { spineLane.configure(nil); return }
        spineLane.duration = duration
        spineLane.configure(.init(track: displayed, clip: clip, descriptor: descriptor, layerID: layerID,
                                  rect: CGRect(x: 0, y: spineY(layerID), width: bounds.width, height: spineHeight(layerID)),
                                  viewport: graphViewport, geometry: geometry))
    }

    private func heightNodeID(_ row: TimelineHeights.Row) -> UUID? {
        guard case let .automation(layerID, parameter) = row, parameter.effectKind != nil else { return nil }
        let layer = visuals.layers.first { $0.id == layerID }
        let clip = layer?.clips.first { $0.id == selectedImageID && $0.automationParameters.contains(parameter) }
            ?? layer?.clips.first { $0.automationParameters.contains(parameter) }
        return clip?.effects?.node(for: parameter)?.id
    }
    private func rowHeight(_ row: TimelineHeights.Row) -> Double {
        if let resize = rowResize, resize.row == row { return resize.height }
        if case let .spine(layerID) = row { return max(spineMinimumHeight(layerID), heights[row]) }
        return heights.height(row, nodeID: heightNodeID(row))
    }

    private func height(of layerID: UUID) -> Double {
        automationParameters(in: layerID).reduce(rowHeight(.visual(layerID)) + spineHeight(layerID)) { $0 + rowHeight(.automation(layerID, $1)) }
    }

    private var contentHeight: Double { layoutHeight }
    private var rowsBottom: Double { min(bounds.height - 24, rowsTop + contentHeight - imageScroll) }
    private var maximumRowScroll: Double {
        let bottom = visualMode ? rowsTop + contentHeight : lyricBoundaryY + lyricScroll
        return max(0, bottom - (bounds.height - 24))
    }

    private var rowBoundaries: [RowBoundary] {
        guard visualMode else { return [RowBoundary(row: .lyrics, y: lyricBoundaryY)] }
        return layoutRows.map { RowBoundary(row: $0.row, y: rowsTop - imageScroll + $0.top + $0.height) }
    }

    private func boundaryHitRect(_ boundary: RowBoundary) -> NSRect {
        let top = visualMode ? rowsTop : lyricViewport.minY
        let bottom = bounds.height - 24
        guard boundary.y >= top, boundary.y <= bottom else { return .zero }
        return NSRect(x: 0, y: boundary.y - 3, width: bounds.width, height: 6)
            .intersection(NSRect(x: 0, y: top, width: bounds.width, height: max(0, bottom - top)))
    }

    private func rowBoundary(at point: NSPoint) -> RowBoundary? {
        rowBoundaries.first { boundaryHitRect($0).contains(point) }
    }

    private func drawRowBoundaries() {
        let hovered = hoverPoint.flatMap { rowBoundary(at: $0)?.row }
        for boundary in rowBoundaries where !boundaryHitRect(boundary).isEmpty {
            let active = rowResize?.row == boundary.row || (rowResize == nil && hovered == boundary.row)
            let color: NSColor = active ? .systemYellow : .white.withAlphaComponent(0.2)
            color.setFill()
            NSRect(x: 0, y: boundary.y - 0.5, width: bounds.width, height: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: 27, y: boundary.y - 1.5, width: 24, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func updateRowResize(with event: NSEvent) {
        guard var resize = rowResize else { return }
        let point = convert(event.locationInWindow, from: nil)
        let range: ClosedRange<Double>
        if case let .spine(layerID) = resize.row { range = spineMinimumHeight(layerID)...resize.row.range.upperBound }
        else { range = resize.row.range }
        resize.height = min(range.upperBound, max(range.lowerBound, resize.initialHeight + point.y - resize.initialY))
        rowResize = resize
        rowScroll = resize.initialScroll
        hoverPoint = point
        updateRowLayout()
    }

    func selectGraph(_ parameter: ImageParameter?, key: UUID? = nil, reveal: Bool = false) {
        if parameter != nil { spineLane.clearSelection() }
        selectedParameter = parameter
        selectedKeyID = key
        if reveal, let parameter, let layerID = selectedImageID.flatMap({ visuals.layerID(of: $0) }),
           let index = automationParameters(in: layerID).firstIndex(of: parameter) {
            revealRows(from: graphY(layerID: layerID, index: index), height: rowHeight(.automation(layerID, parameter)) - graphPadding)
        }
        onGraphSelection?()
        needsDisplay = true
    }

    func resetGraphDisclosure() {
        expandedLayerIDs.removeAll()
        imageScroll = 0
        lyricScroll = 0
        updateGraphLayout()
    }

    func revealAutomation(in layerID: UUID) {
        setAutomationExpanded(true, in: layerID)
        if spineHeight(layerID) > 0 {
            revealRows(from: spineY(layerID), height: min(spineHeight(layerID), max(1, rowsBottom - rowsTop)))
        }
    }

    private func setAutomationExpanded(_ expanded: Bool, in layerID: UUID) {
        cancelDrag()
        if expanded { expandedLayerIDs.insert(layerID) }
        else { expandedLayerIDs.remove(layerID) }
        updateGraphLayout()
        let firstLaneHeight = automationParameters(in: layerID).first.map { rowHeight(.automation(layerID, $0)) } ?? 0
        revealRows(from: rowY(layerID), height: rowHeight(.visual(layerID)) + firstLaneHeight)
    }

    func revealLayer(_ id: UUID) { revealRows(from: rowY(id), height: rowHeight(.visual(id))) }

    private func revealRows(from top: Double, height: Double) {
        if top + height > rowsBottom { rowScroll += top + height - rowsBottom }
        if top < rowsTop { rowScroll += top - rowsTop }
        updateRowLayout()
    }

    private func updateRowLayout() {
        layoutRows = []; layerOffsets = [:]; layoutHeight = 0
        for layer in visuals.layers.reversed() {
            layerOffsets[layer.id] = layoutHeight
            var rows: [TimelineHeights.Row] = [.visual(layer.id)]
            rows += automationParameters(in: layer.id).map { .automation(layer.id, $0) }
            if spineHeight(layer.id) > 0 { rows.append(.spine(layer.id)) }
            for row in rows {
                let height = rowHeight(row)
                layoutRows.append(LayoutRow(row: row, top: layoutHeight, height: height))
                layoutHeight += height
            }
        }
        rowScroll = min(maximumRowScroll, max(0, rowScroll))
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func updateGraphLayout() {
        updateRowLayout()
        if let parameter = selectedParameter,
           let curve = visuals.clip(selectedImageID)?.displayCurve(parameter) {
            if let key = selectedKeyID, !curve.keys.contains(where: { $0.id == key }) { selectGraph(parameter) }
        } else if selectedParameter != nil {
            selectGraph(nil)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelDrag(); layerNameField?.onFinish = nil; layerNameField?.removeFromSuperview(); layerNameField = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRowLayout()
    }

    override func scrollWheel(with event: NSEvent) {
        guard rowResize == nil, layerDrag == nil, layerNameField == nil else { return }
        let modifiers = event.modifierFlags
        if !modifiers.intersection([.command, .shift, .option]).isEmpty {
            guard isEnabled, frozenGeometry == nil, event.momentumPhase.isEmpty else { return }
            let precise = event.hasPreciseScrollingDeltas
            let y = precise ? event.scrollingDeltaY : event.deltaY
            let steps = precise ? y / 10 : y
            if modifiers.contains(.command) {
                guard steps.isFinite, steps != 0 else { return }
                onWheelZoom?(steps)
            } else if modifiers.contains(.shift) {
                let x = precise ? event.scrollingDeltaX : event.deltaX
                scrollHorizontally(by: (x == 0 ? y : x) * (precise ? 1 : 40))
            } else {
                seekByWheel(steps: steps)
            }
            return
        }
        guard maximumRowScroll > 0, frozenGeometry == nil else { super.scrollWheel(with: event); return }
        rowScroll -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
        updateRowLayout()
    }

    private func seekByWheel(steps: Double) {
        guard steps.isFinite, steps != 0, duration > 0, let onSeek else { return }
        let viewport = geometry
        let time = min(duration, max(0, currentTime - steps * (viewport.span / 60)))
        if time < viewport.origin || time > viewport.origin + viewport.span {
            followPlayhead()
        }
        onSeek(time)
    }

    private func scrollHorizontally(by points: Double) {
        guard points.isFinite, points != 0, duration > 0, timeViewport.width > 0 else { return }
        let viewport = geometry
        let next = TimelineGeometry.clampOrigin(viewport.origin - points / viewport.pointsPerSecond,
                                                duration: duration, span: viewport.span)
        if next != viewport.origin { manualOrigin = next }
    }

    private func layerID(at point: NSPoint) -> UUID? {
        guard point.y >= rowsTop, point.y < rowsBottom else { return nil }
        return visuals.layers.map(\.id).first { layerID in
            let y = rowY(layerID)
            return point.y >= y && point.y < y + height(of: layerID)
        }
    }

    private func rowY(_ layerID: UUID) -> Double {
        rowsTop - imageScroll + (layerOffsets[layerID] ?? 0)
    }

    private func disclosureRect(for layerID: UUID) -> NSRect {
        let rowHeight = rowHeight(.visual(layerID))
        let height = min(29, rowHeight - 6)
        return NSRect(x: 194, y: rowY(layerID) + (rowHeight - height) / 2, width: 22, height: height)
    }

    private func graphY(layerID: UUID, index: Int) -> Double {
        automationParameters(in: layerID).prefix(index).reduce(rowY(layerID) + rowHeight(.visual(layerID)) + graphPadding) {
            $0 + rowHeight(.automation(layerID, $1))
        }
    }

    private func graphLanes(in displayed: VisualTrack) -> [GraphLane] {
        displayed.layers.flatMap { layer in
            let parameters = automationParameters(in: layer.id)
            guard !parameters.isEmpty else { return [GraphLane]() }
            return layer.clips.filter { $0.end >= geometry.origin && $0.start <= geometry.origin + geometry.span }.flatMap { clip in
                parameters.enumerated().compactMap { index, parameter in
                    guard let curve = clip.displayCurve(parameter) else { return nil }
                    let left = x(at: clip.start)
                    let rect = NSRect(x: left, y: graphY(layerID: layer.id, index: index),
                                      width: x(at: clip.end) - left, height: rowHeight(.automation(layer.id, parameter)) - 2 * graphPadding)
                    return GraphLane(clip: clip, curve: curve, rect: rect)
                }
            }
        }
    }
    private func imageRect(_ clip: VisualClip, layerID: UUID) -> NSRect {
        NSRect(x: x(at: clip.start), y: rowY(layerID) + 3, width: x(at: clip.end) - x(at: clip.start), height: rowHeight(.visual(layerID)) - 7)
    }
    private var graphViewport: NSRect {
        NSRect(x: Self.gutter + TimelineGeometry.inset, y: rowsTop,
                                width: max(0, bounds.width - Self.gutter - 2 * TimelineGeometry.inset),
                                height: max(0, rowsBottom - rowsTop))
    }

    private func drawImages() {
        let clipBounds = graphViewport
        let displayed = keyDrag?.draft ?? imageDrag?.draft ?? automationPreview ?? visuals
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
        let selectedLayer = selectedImageID.flatMap { displayed.layerID(of: $0) }
        for layerID in visuals.layers.map(\.id) where rowY(layerID) + height(of: layerID) >= rowsTop && rowY(layerID) < rowsBottom {
            if layerID == (imageDrag?.targetLayerID ?? selectedLayerID) {
                NSColor.white.withAlphaComponent(0.04).setFill()
                NSRect(x: 0, y: rowY(layerID), width: bounds.width, height: height(of: layerID)).fill()
            }
            drawLayerControls(layerID)
            let rowCenter = rowY(layerID) + rowHeight(.visual(layerID)) / 2
            label(visuals.layer(layerID)?.name ?? "レイヤー",
                  rect: NSRect(x: 70, y: rowCenter - 8, width: 104, height: 16), color: .lightGray, size: 11)
            if hasAutomation(in: layerID) {
                let button = disclosureRect(for: layerID)
                label(expandedLayerIDs.contains(layerID) ? "v" : ">",
                      rect: NSRect(x: button.minX + 6, y: button.midY - 7.5, width: 16, height: 15),
                      color: .white.withAlphaComponent(0.45), size: 12)
            }
            let clip = selectedLayer == layerID ? selectedClip : nil
            for (index, parameter) in automationParameters(in: layerID).enumerated() {
                let color: NSColor = clip != nil && parameter == selectedParameter ? .cyan : .lightGray
                let y = graphY(layerID: layerID, index: index)
                label(parameter.title + (clip?.activeLFO(parameter) != nil ? " [LFO]" : ""), rect: NSRect(x: 5, y: y, width: 73, height: 16), color: color, size: 11)
                if showsGraphRange(layerID: layerID, parameter: parameter), let curve = clip?.displayCurve(parameter) {
                    label("最大 " + Self.graphNumber(curve.maximum), rect: NSRect(x: 5, y: y + 17, width: 73, height: 14), color: color, size: 9)
                    label("最小 " + Self.graphNumber(curve.minimum), rect: NSRect(x: 5, y: y + 32, width: 73, height: 14), color: color, size: 9)
                }
            }
        }
        configureSpineLane(displayed: displayed)
        spineLane.draw()
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
                let clipRect = imageRect(clip, layerID: layer.id)
                let rect = clipRect.intersection(clipBounds)
                guard !rect.isEmpty else { continue }
                let missing = clip.assetID.map { missingAssets.contains($0) } ?? false
                (missing ? NSColor.systemRed : NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.57, alpha: 1)).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 0), xRadius: 4, yRadius: 4).fill()
                if !layer.isVisible {
                    NSColor(calibratedWhite: 0.08, alpha: 0.6).setFill(); rect.fill()
                }
            }
            drawCrossfades(layer)
            for clip in layer.clips {
                let clipRect = imageRect(clip, layerID: layer.id)
                let rect = clipRect.intersection(clipBounds)
                guard !rect.isEmpty else { continue }
                let missing = clip.assetID.map { missingAssets.contains($0) } ?? false
                let title = (missing ? "⚠ " : "") + (clip.content.sourceIn == nil ? "" : "▶ ") + (displayed.asset(clip.assetID)?.name ?? "空のクリップ")
                var textRect = rect
                for transition in LayerCrossfade.transitions(in: layer.clips) {
                    let midpoint = x(at: (transition.start + transition.end) / 2)
                    if transition.outgoingID == clip.id { textRect.size.width = max(0, min(textRect.maxX, midpoint) - textRect.minX) }
                    if transition.incomingID == clip.id {
                        let end = textRect.maxX
                        textRect.origin.x = max(textRect.minX, midpoint)
                        textRect.size.width = max(0, end - textRect.minX)
                    }
                }
                drawClipLabels(title, timing: clipTiming(start: clip.start, end: clip.end), in: clipRect, visible: textRect)
                drawClipGrips(in: clipRect, visible: rect)
                if clip.id == selectedImageID { NSColor.cyan.setStroke(); NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).stroke() }
            }
        }
        let highlight = highlightedKey(in: lanes)
        if highlight == nil, canEditClips, let point = hoverPoint, let layerID = layerID(at: point) {
            drawTrimHighlight(imageHit(at: point, layerID: layerID))
        }
        let bendHighlight = highlightedBend(in: lanes)
        for lane in lanes {
            let bendID = bendHighlight.flatMap {
                $0.lane.clip.id == lane.clip.id && $0.lane.curve.parameter == lane.curve.parameter ? $0.key.id : nil
            }
            drawGraph(lane, clippedTo: clipBounds, excluding: highlight?.key.id, highlightedBend: bendID)
        }
        if let drag = imageDrag, drag.error != nil, let layerID = drag.targetLayerID, let clip = drag.original.clip(drag.id) {
            NSColor.systemRed.setStroke()
            let outline = NSBezierPath(roundedRect: imageRect(clip, layerID: layerID).insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            outline.lineWidth = 2; outline.stroke()
        }
        if let candidate = dropCandidate {
            NSColor.cyan.withAlphaComponent(0.35).setFill()
            NSRect(x: x(at: candidate.start), y: rowY(candidate.layerID) + 3, width: x(at: candidate.end) - x(at: candidate.start),
                   height: rowHeight(.visual(candidate.layerID)) - 7).fill()
        }
        if !capturingLayerDrag {
            NSColor.systemPink.setStroke()
            let head = NSBezierPath(); head.lineWidth = 2; head.move(to: NSPoint(x: x(at: currentTime), y: rowsTop)); head.line(to: NSPoint(x: x(at: currentTime), y: rowsBottom)); head.stroke()
        }
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
        let hint = !expandedLayerIDs.isEmpty ? "グラフ：クリックで点を追加、○を上下でカーブ・幅・周期を調整、Deleteで点を削除　｜　上下スクロール　Esc：取消" : "本体：左右で時刻移動・上下で段移動　端：開始/終了　Esc：取消"
        label(imageDrag?.error ?? hint, rect: NSRect(x: 14, y: bounds.height - 19, width: bounds.width - 28, height: 16), color: .lightGray, size: 10)
    }
    private func imageMouseDown(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let frozen = geometry
        configureSpineLane(displayed: visuals)
        if visuals.canEdit(selectedLayerID), spineLane.mouseDown(point) { needsDisplay = true; return }
        if graphMouseDown(at: point, geometry: frozen) { return }
        if let layerID = layerID(at: point) {
            if hasAutomation(in: layerID), disclosureRect(for: layerID).contains(point) {
                setAutomationExpanded(!expandedLayerIDs.contains(layerID), in: layerID)
                return
            }
            selectedLayerID = layerID
            if let hit = imageHit(at: point, layerID: layerID) {
                selectVisualClip(hit.id, layerID: layerID)
                guard visuals.canEdit(layerID) else { return }
                onBeginEdit?()
                imageDrag = ImageDrag(original: visuals, geometry: frozen, id: hit.id, part: hit.part, initialX: point.x, draft: visuals, targetLayerID: layerID, error: nil)
                return
            }
            selectedImageID = nil; onImageSelect?(nil, layerID)
        }
        guard point.x >= Self.gutter else { return }
        onBeginEdit?(); scrubGeometry = frozen; seek(at: point.x, geometry: frozen)
    }
    private func imageMouseDragged(_ event: NSEvent) {
        if spineLane.frozenGeometry != nil { spineLane.mouseDragged(convert(event.locationInWindow, from: nil), grid: keySnapEnabled ? snapGrid : nil, duration: duration); return }
        let point = convert(event.locationInWindow, from: nil)
        if keyDrag != nil { updateKeyDrag(to: point); return }
        if var drag = imageDrag {
            drag.hasDragged = true
            drag.targetLayerID = drag.part == .move ? layerID(at: point) : drag.original.layerID(of: drag.id)
            do {
                guard layerID(at: point) != nil, let destination = drag.targetLayerID, point.x >= Self.gutter, point.x <= bounds.width - TimelineGeometry.inset else {
                    throw StudioError.message("画像行の上で離してください。範囲外では移動を取り消します。")
                }
                if drag.part == .move, destination != drag.original.layerID(of: drag.id), let clip = drag.original.clip(drag.id) {
                    drag.draft = try drag.original.updating(clip, layerID: destination, duration: duration)
                } else {
                    drag.draft = try drag.original.dragging(id: drag.id, part: drag.part, delta: (point.x - drag.initialX) / drag.geometry.pointsPerSecond, duration: duration, grid: snapGrid)
                }
                drag.error = nil
                NSCursor.closedHand.set()
            } catch {
                drag.error = error.localizedDescription
                NSCursor.operationNotAllowed.set(); onError?(error)
            }
            imageDrag = drag; onImagePreview?(drag.draft); needsDisplay = true
        } else if let geometry = scrubGeometry { seek(at: point.x, geometry: geometry) }
    }
    private func imageMouseUp(_ event: NSEvent) {
        if spineLane.mouseUp(convert(event.locationInWindow, from: nil), grid: keySnapEnabled ? snapGrid : nil, duration: duration) { needsDisplay = true; return }
        if keyDrag != nil {
            finishKeyDrag(at: convert(event.locationInWindow, from: nil))
            return
        }
        if imageDrag?.hasDragged == true { imageMouseDragged(event) }
        NSCursor.arrow.set()
        if let drag = imageDrag {
            imageDrag = nil
            if drag.error == nil, drag.original != drag.draft { onImageCommit?(drag.draft, drag.id) }
            else { onImagePreview?(drag.original) }
        }
        scrubGeometry = nil; needsDisplay = true
    }

    private func droppedURL(_ pasteboard: NSPasteboard) -> URL? {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard objects.count == 1, let url = objects.first, ["png", "jpg", "jpeg", "tif", "tiff", "mp4", "mov", "m4v", "json"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard visualMode, isEnabled, imageDrag == nil, keyDrag == nil, drag == nil, rowResize == nil else { return [] }
        dropGeometry = geometry
        return draggingUpdated(sender)
    }
    func fileDrop(at point: NSPoint, pasteboard: NSPasteboard) throws -> (url: URL, layerID: UUID, start: Double, end: Double) {
        guard visualMode, isEnabled, imageDrag == nil, keyDrag == nil, drag == nil, rowResize == nil, let url = droppedURL(pasteboard),
              point.x >= Self.gutter + TimelineGeometry.inset, point.x <= bounds.width - TimelineGeometry.inset,
              let layerID = layerID(at: point), point.y < rowY(layerID) + rowHeight(.visual(layerID)) else { throw StudioError.message("画像・動画を1ファイルずつ、配置可能な素材行にドロップしてください。") }
        let range = try visuals.placement(at: geometry.time(at: point.x - Self.gutter), layerID: layerID, duration: duration, grid: snapGrid)
        return (url, layerID, range.start, range.end)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropCandidate = nil; needsDisplay = true
        do {
            let value = try fileDrop(at: convert(sender.draggingLocation, from: nil), pasteboard: sender.draggingPasteboard)
            dropCandidate = (value.layerID, value.start, value.end)
            return .copy
        } catch { return [] }
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropGeometry = nil; dropCandidate = nil; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingUpdated(sender) == .copy }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { draggingExited(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingUpdated(sender) == .copy, let candidate = dropCandidate, let url = droppedURL(sender.draggingPasteboard) else {
            onError?(StudioError.message("画像・動画を1ファイルずつ、配置可能な素材行にドロップしてください。")); draggingExited(sender); return false
        }
        onBeginEdit?()
        onDropImage?(url, candidate.layerID, candidate.start)
        draggingExited(sender)
        return true
    }
    var onLayerAction: ((UUID, VisualLayerAction) -> Void)?
    var onLayerPreview: ((VisualTrack) -> Void)?
    var onLayerCommit: ((VisualTrack, UUID) -> Void)?
    private var layerDrag: LayerDrag?
    private var layerScrollTimer: Timer?
    private var layerNameField: LayerNameField?
    private var capturingLayerDrag = false
    private struct LayerDrag {
        let original: VisualTrack
        let id: UUID
        let initial: NSPoint
        let image: NSImage
        let grabOffset: Double
        var point: NSPoint
        var insertionY: Double?
        var changed = false
    }
    private var addLayerRect: NSRect { NSRect(x: 5, y: 24, width: Self.gutter - 10, height: 21) }
    private func headerRect(_ id: UUID) -> NSRect {
        NSRect(x: 0, y: rowY(id), width: Self.gutter, height: rowHeight(.visual(id)))
    }
    struct LayerDragPresentation {
        let sourceRect: NSRect
        let floatingRect: NSRect
    }
    private var layerDragViewport: NSRect {
        NSRect(x: bounds.minX, y: rowsTop, width: bounds.width, height: max(0, bounds.height - rowsTop - 24))
    }
    private func layerGroupRect(_ id: UUID) -> NSRect {
        NSRect(x: bounds.minX, y: rowY(id), width: bounds.width, height: height(of: id))
    }
    var layerDragPresentation: LayerDragPresentation? {
        guard let drag = layerDrag, drag.changed else { return nil }
        return LayerDragPresentation(sourceRect: layerGroupRect(drag.id),
            floatingRect: NSRect(x: bounds.minX, y: drag.point.y - drag.grabOffset,
                                 width: drag.image.size.width, height: drag.image.size.height))
    }
    private func captureLayerGroup(_ id: UUID) -> (NSRect, NSImage)? {
        let rect = layerGroupRect(id).intersection(layerDragViewport)
        guard !rect.isEmpty, let bitmap = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        capturingLayerDrag = true
        defer { capturingLayerDrag = false }
        cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size); image.addRepresentation(bitmap)
        return (rect, image)
    }

    private func drawLayerDragPresentation() {
        guard let drag = layerDrag, let presentation = layerDragPresentation else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: layerDragViewport).addClip()
        NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 0.7).setFill()
        presentation.sourceRect.fill()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 4; shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        drag.image.draw(in: presentation.floatingRect, from: .zero, operation: .sourceOver,
                        fraction: 0.85, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        NSBezierPath(rect: presentation.floatingRect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        if let y = drag.insertionY, layerDragViewport.contains(drag.point) {
            NSColor.systemYellow.setFill()
            NSRect(x: bounds.minX, y: y - 1, width: bounds.width, height: 2).fill()
        }
    }

    private func drawLayerControls(_ id: UUID) {
        guard let layer = visuals.layer(id) else { return }
        let y = headerRect(id).midY - 8
        if let drag = layerDrag, let index = visuals.layers.firstIndex(where: { $0.id == drag.id }),
           drag.id == id || (index > 0 && visuals.layers[index - 1].id == id && visuals.layer(drag.id)?.clips.contains(where: { $0.effects?.belowMask != nil }) == true) {
            NSColor.systemYellow.withAlphaComponent(0.15).setFill(); headerRect(id).fill()
        }
        for (text, x) in [("≡", 5.0), (layer.isVisible ? "●" : "○", 25.0), ("⋯", 174.0)] {
            label(text, rect: NSRect(x: x, y: y, width: 21, height: 17), color: .lightGray, size: 12)
        }
        let lockRect = NSRect(x: 47, y: y, width: 21, height: 17)
        if layer.isLocked { label("🔐", rect: lockRect, color: .lightGray, size: 12) }
        else { unlockedLayerIcon?.draw(in: lockRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    }
    private lazy var unlockedLayerIcon: NSImage? = {
        let size = NSSize(width: 21, height: 17)
        let image = NSImage(size: size, flipped: true) { rect in
            ("🔓" as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
            return true
        }
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 42, height: 34, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: 42, height: 34))
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }()
    private func layerHeaderDown(_ event: NSEvent, point: NSPoint) -> Bool {
        guard point.x < Self.gutter else { return false }
        if addLayerRect.contains(point) { onLayerAction?(selectedLayerID, .add(above: true)); return true }
        guard let id = layerID(at: point), headerRect(id).contains(point) else { return false }
        if hasAutomation(in: id), disclosureRect(for: id).contains(point) {
            setAutomationExpanded(!expandedLayerIDs.contains(id), in: id); return true
        }
        if point.x >= 174 { if let menu = layerMenu(id) { NSMenu.popUpContextMenu(menu, with: event, for: self) }; return true }
        if point.x >= 47 && point.x < 70 { onLayerAction?(id, .lock); return true }
        if point.x >= 25 && point.x < 47 { onLayerAction?(id, .visibility); return true }
        if point.x < 25, visuals.canEdit(id) {
            onBeginEdit?()
            guard let (source, image) = captureLayerGroup(id) else { return true }
            layerDrag = LayerDrag(original: visuals, id: id, initial: point, image: image,
                                  grabOffset: point.y - source.minY, point: point)
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let drag = self.layerDrag, drag.changed else { return }
                    let delta = drag.point.y < self.rowsTop + 25 ? -8.0 : drag.point.y > self.bounds.height - 49 ? 8.0 : 0
                    guard delta != 0 else { return }
                    self.rowScroll += delta; self.updateRowLayout(); self.updateLayerDrag(drag.point)
                }
            }
            layerScrollTimer = timer; RunLoop.main.add(timer, forMode: .common)
            return true
        }
        if event.clickCount == 2 { beginLayerRename(id); return true }
        if selectedLayerID != id { selectedImageID = nil; onImageSelect?(nil, id) }
        selectedLayerID = id; needsDisplay = true
        return true
    }
    private func updateLayerDrag(_ point: NSPoint) {
        guard var drag = layerDrag else { return }
        drag.point = point
        guard drag.changed || hypot(point.x - drag.initial.x, point.y - drag.initial.y) >= 5 else { layerDrag = drag; return }
        drag.changed = true
        if point.x >= 0, point.x <= bounds.width, let target = layerID(at: point), target != drag.id {
            let above = point.y < rowY(target) + height(of: target) / 2
            if let draft = try? drag.original.movingLayer(drag.id, relativeTo: target, above: above) {
                visuals = draft
                drag.insertionY = rowY(drag.id)
                onLayerPreview?(draft); onImagePreview?(draft)
            }
        }
        layerDrag = drag; NSCursor.closedHand.set(); needsDisplay = true
    }
    private func finishLayerDrag(_ point: NSPoint) {
        guard let drag = layerDrag else { return }
        let valid = point.x >= 0 && point.x <= bounds.width && point.y >= rowsTop && point.y < bounds.height - 24
        if valid { updateLayerDrag(point) }
        let result = visuals
        layerScrollTimer?.invalidate(); layerScrollTimer = nil; layerDrag = nil
        visuals = drag.original
        NSCursor.arrow.set()
        if valid, result != drag.original { onLayerCommit?(result, selectedLayerID) }
        else if drag.changed { onLayerPreview?(drag.original); onImagePreview?(drag.original) }
        needsDisplay = true
    }
    private func layerMenu(_ id: UUID) -> NSMenu? {
        guard let layer = visuals.layer(id) else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        let actions: [(String, VisualLayerAction)] = [("上にレイヤーを追加", .add(above: true)), ("下にレイヤーを追加", .add(above: false)), ("前へ移動", .move(forward: true)), ("後ろへ移動", .move(forward: false)), ("名前変更…", .rename), (layer.isVisible ? "非表示にする" : "表示する", .visibility), (layer.isLocked ? "ロック解除" : "ロック", .lock), ("レイヤーを削除…", .delete)]
        for (title, action) in actions {
            let item = menu.addItem(withTitle: title, action: #selector(performLayerAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = LayerMenuTarget(id: id, action: action)
            switch action {
            case .add: item.isEnabled = visuals.layers.count < VisualTrack.maximumLayers
            case .lock: break
            case .delete: item.isEnabled = !layer.isLocked && visuals.layers.count > 1
            case .move(let forward): item.isEnabled = !layer.isLocked && (forward ? visuals.layers.last?.id : visuals.layers.first?.id) != id
            default: item.isEnabled = !layer.isLocked
            }
        }
        return menu
    }
    private struct LayerMenuTarget { let id: UUID; let action: VisualLayerAction }
    @objc private func performLayerAction(_ item: NSMenuItem) {
        guard canEditClips, let target = item.representedObject as? LayerMenuTarget else { return }
        if case .rename = target.action { beginLayerRename(target.id) }
        else { onLayerAction?(target.id, target.action) }
    }
    func beginLayerRename(_ id: UUID) {
        guard isEnabled, visuals.canEdit(id), let layer = visuals.layer(id) else { return }
        layerNameField?.removeFromSuperview()
        let field = LayerNameField(string: layer.name)
        let rect = headerRect(id)
        field.frame = NSRect(x: 70, y: rect.midY - 11, width: 104, height: 22)
        field.onFinish = { [weak self, weak field] name in
            guard let self else { return }
            field?.removeFromSuperview(); self.layerNameField = nil
            guard let name else { return }
            do {
                let result = try self.visuals.editingLayer(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                self.onLayerCommit?(result, self.selectedLayerID)
            } catch { self.onError?(error) }
        }
        layerNameField = field; addSubview(field); field.selectText(nil)
    }

}

private extension TimelineView {
    private static func graphNumber(_ value: Double) -> String { String(format: "%.5g", value) }

    private func drawGraph(_ lane: GraphLane, clippedTo clipBounds: NSRect, excluding highlightedID: UUID?, highlightedBend: UUID?) {
        let visible = lane.rect.intersection(clipBounds)
        guard !visible.isEmpty else { return }
        let active = lane.clip.id == selectedImageID && lane.curve.parameter == selectedParameter
        let color: NSColor = active ? .systemCyan : .systemTeal
        color.withAlphaComponent(active ? 0.20 : 0.12).setFill()
        visible.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: visible.insetBy(dx: -keyMarkerRadius, dy: -keyMarkerRadius)).addClip()

        if lane.clip.activeLFO(lane.curve.parameter) != nil {
            drawLFO(lane, visible: visible, color: color)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        // Sample the shared evaluator and split at display-range crossings.
        let first = max(0, geometry.time(at: visible.minX - Self.gutter) - lane.clip.start)
        let last = min(lane.clip.end - lane.clip.start, geometry.time(at: visible.maxX - Self.gutter) - lane.clip.start)
        let samples = lane.curve.keys.isEmpty ? [(first, lane.clip.baseValue(lane.curve.parameter)), (last, lane.clip.baseValue(lane.curve.parameter))] : lane.curve.plotSamples(from: first, through: last, steps: Int(ceil(visible.width / 2)))
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
        if let modulation = lane.clip.audioModulations[lane.curve.parameter], modulation.enabled {
            let start = lane.clip.start + first, end = lane.clip.start + last
            let events = modulation.events(from: start, through: end, settings: sceneSettings, features: audioFeatures)
            let combined = ParameterEvaluator.plotSamples(lane.curve.parameter, clip: lane.clip, from: start, through: end,
                                                         steps: max(1, Int(ceil(visible.width))), settings: sceneSettings, features: audioFeatures)
            let result = NSBezierPath()
            for (index, sample) in combined.enumerated() {
                let point = NSPoint(x: x(at: sample.0), y: lane.y(at: sample.1))
                if index == 0 { result.move(to: point) } else { result.line(to: point) }
            }
            NSColor.systemPink.setStroke(); result.lineWidth = 1; result.stroke()
            let ticks = NSBezierPath()
            for event in events {
                ticks.move(to: NSPoint(x: x(at: event), y: visible.maxY - 5))
                ticks.line(to: NSPoint(x: x(at: event), y: visible.maxY))
            }
            ticks.stroke()
        }
        let markerBounds = visible.insetBy(dx: -keyMarkerRadius, dy: -keyMarkerRadius)
        for key in lane.curve.keys where key.id != highlightedID && lane.clip.containsKey(key) {
            let center = keyPosition(key, in: lane)
            guard markerBounds.contains(center) else { continue }
            let selected = active && key.id == selectedKeyID
            drawKey(key, in: lane, at: center, radius: keyMarkerRadius, color: selected ? .white : color)
        }
        for key in lane.curve.keys {
            guard let center = bendPosition(after: key.id, in: lane), markerBounds.contains(center) else { continue }
            let hot = highlightedBend == key.id
            let radius = hot ? highlightedKeyRadius : keyMarkerRadius
            (hot ? NSColor.systemYellow : color).setStroke()
            let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                    width: 2 * radius, height: 2 * radius))
            NSColor.windowBackgroundColor.setFill()
            circle.fill()
            circle.lineWidth = 1.5
            circle.stroke()
            if hot, let text = lane.curve.midpointLabel(after: key.id) {
                let textY = center.y - visible.minY >= 22 ? center.y - 22 : center.y + 8
                let textWidth = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width + 4
                label(text, rect: NSRect(x: max(visible.minX, min(visible.maxX - textWidth, center.x + 9)),
                                        y: min(visible.maxY - 14, max(visible.minY, textY)), width: textWidth, height: 14),
                      color: .systemYellow, size: 10)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLFO(_ lane: GraphLane, visible: NSRect, color: NSColor) {
        let parameter = lane.curve.parameter
        let first = max(lane.clip.start, geometry.time(at: visible.minX - Self.gutter))
        let last = min(lane.clip.end, geometry.time(at: visible.maxX - Self.gutter))
        let base = lane.clip.baseValue(parameter)
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: visible.minX, y: lane.y(at: base)))
        baseline.line(to: NSPoint(x: visible.maxX, y: lane.y(at: base)))
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke(); baseline.stroke()
        let plot = ParameterEvaluator.lfoPlot(parameter, clip: lane.clip, from: first, through: last,
            pixels: max(1, Int(visible.width)), settings: sceneSettings, features: audioFeatures)
        let samples = plot.samples
        if plot.isEnvelope {
            let values = samples.map(\.1)
            let low = lane.y(at: values.min() ?? base), high = lane.y(at: values.max() ?? base)
            color.withAlphaComponent(0.3).setFill()
            NSRect(x: visible.minX, y: min(low, high), width: visible.width, height: max(1, abs(high - low))).fill()
        } else {
            let path = NSBezierPath()
            for (index, sample) in samples.enumerated() {
                let point = NSPoint(x: x(at: sample.0), y: lane.y(at: sample.1))
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            color.setStroke(); path.lineWidth = 1.5; path.stroke()
        }
    }

    private func bendPosition(after id: UUID, in lane: GraphLane) -> NSPoint? {
        guard let midpoint = lane.curve.midpoint(after: id),
              midpoint.time >= 0, midpoint.time <= lane.clip.end - lane.clip.start else { return nil }
        return NSPoint(x: x(at: lane.clip.start + midpoint.time), y: lane.y(at: midpoint.value))
    }

    private func graphBend(at point: NSPoint, in lanes: [GraphLane]) -> (lane: GraphLane, key: ImageKeyframe)? {
        guard graphViewport.contains(point), graphKey(at: point, in: lanes) == nil else { return nil }
        var hit: (lane: GraphLane, key: ImageKeyframe, distance: Double)?
        for lane in lanes where lane.rect.insetBy(dx: -keyHitRadius, dy: -graphPadding).contains(point) {
            for key in lane.curve.keys {
                guard let center = bendPosition(after: key.id, in: lane), graphViewport.contains(center) else { continue }
                let distance = hypot(center.x - point.x, center.y - point.y)
                guard distance <= keyHitRadius else { continue }
                if let hit, hit.distance < distance || (hit.distance == distance && hit.lane.clip.id == selectedImageID) { continue }
                hit = (lane, key, distance)
            }
        }
        return hit.map { ($0.lane, $0.key) }
    }

    private func highlightedBend(in lanes: [GraphLane]) -> (lane: GraphLane, key: ImageKeyframe)? {
        guard isEnabled, imageDrag == nil, scrubGeometry == nil, dropGeometry == nil, automationPreview == nil else { return nil }
        if let drag = keyDrag {
            guard let id = drag.bendKeyID,
                  let lane = lanes.first(where: { $0.clip.id == drag.lane.clip.id && $0.curve.parameter == drag.lane.curve.parameter }),
                  let key = lane.curve.keys.first(where: { $0.id == id }) else { return nil }
            return (lane, key)
        }
        return hoverPoint.flatMap { graphBend(at: $0, in: lanes) }
    }

    private func keyPosition(_ key: ImageKeyframe, in lane: GraphLane) -> NSPoint {
        NSPoint(x: x(at: lane.clip.start + key.time), y: lane.y(at: key.value))
    }

    private func drawKey(_ key: ImageKeyframe, in lane: GraphLane, at center: NSPoint, radius: Double, color: NSColor) {
        let marker = NSBezierPath()
        let top = key.value < lane.curve.minimum ? 0 : min(radius, center.y - lane.rect.minY + graphPadding)
        let bottom = key.value > lane.curve.maximum ? 0 : min(radius, lane.rect.maxY - center.y + graphPadding)
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
        for lane in lanes where lane.rect.insetBy(dx: -keyHitRadius, dy: -graphPadding).contains(point) {
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

    private struct GraphTarget {
        let clipID: UUID
        let parameter: ImageParameter
    }

    private func graphLabel(at point: NSPoint) -> (target: GraphTarget, localY: Double)? {
        guard point.x >= 0, point.x < Self.gutter,
              let layerID = layerID(at: point), let clip = visuals.clip(selectedImageID),
              visuals.layerID(of: clip.id) == layerID else { return nil }
        for (index, parameter) in automationParameters(in: layerID).enumerated() {
            let localY = point.y - graphY(layerID: layerID, index: index)
            if (0...(rowHeight(.automation(layerID, parameter)) - 2 * graphPadding)).contains(localY), clip.displayCurve(parameter) != nil {
                return (GraphTarget(clipID: clip.id, parameter: parameter), localY)
            }
        }
        return nil
    }

    private func showsGraphRange(layerID: UUID, parameter: ImageParameter) -> Bool {
        rowHeight(.automation(layerID, parameter)) >= 54
    }

    private func graphMouseDown(at point: NSPoint, geometry: TimelineGeometry) -> Bool {
        if let label = graphLabel(at: point) {
            let parameter = label.target.parameter
            selectGraph(parameter, key: selectedParameter == parameter ? selectedKeyID : nil)
            if let layerID = visuals.layerID(of: label.target.clipID),
               showsGraphRange(layerID: layerID, parameter: parameter), label.localY >= 17 {
                onGraphRangeEdit?(label.localY < 32)
            }
            return true
        }
        guard graphViewport.contains(point) else { return false }
        let lanes = graphLanes(in: visuals)
        let hit = graphKey(at: point, in: lanes)
        let bend = hit == nil ? graphBend(at: point, in: lanes) : nil
        guard let lane = hit?.lane ?? bend?.lane ?? lanes.first(where: { $0.rect.contains(point) }),
              let layerID = visuals.layerID(of: lane.clip.id) else { return false }
        guard visuals.canEdit(layerID) else { return true }
        let key = hit?.key
        if selectedImageID != lane.clip.id {
            selectedLayerID = layerID
            selectedImageID = lane.clip.id
            onImageSelect?(lane.clip.id, layerID)
        }
        if hit == nil, bend == nil, let modulation = lane.clip.audioModulations[lane.curve.parameter], modulation.enabled {
            let time = geometry.time(at: point.x - Self.gutter)
            let combined = ParameterEvaluator.value(lane.curve.parameter, clip: lane.clip, at: time, settings: sceneSettings, features: audioFeatures)
            let manual = lane.clip.manualValue(lane.curve.parameter, at: time)
            if abs(point.y - lane.y(at: combined)) <= 4, abs(point.y - lane.y(at: manual)) > 4 {
                selectGraph(lane.curve.parameter)
                return true
            }
        }
        if lane.clip.activeLFO(lane.curve.parameter) != nil {
            selectGraph(lane.curve.parameter)
            return true
        }
        onBeginEdit?()
        keyDrag = KeyDrag(original: visuals, geometry: geometry, lane: lane, key: key, bendKeyID: bend?.key.id, initial: point, previousTime: currentTime)
        selectGraph(lane.curve.parameter, key: key?.id)
        if let key { onSeek?(lane.clip.start + key.time) }
        return true
    }

    private func updateKeyDrag(to point: NSPoint) {
        if let drag = keyDrag, drag.bendKeyID != nil {
            updateBendDrag(to: point)
            return
        }
        guard var drag = keyDrag, let key = drag.key,
              let layerID = drag.original.layerID(of: drag.lane.clip.id) else { return }
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
            drag.draft = try drag.original.updating(clip, layerID: layerID, duration: duration)
            onSeek?(time)
        } catch {
            drag.draft = nil
            onError?(error)
        }
        keyDrag = drag
        onImagePreview?(drag.draft ?? drag.original)
        needsDisplay = true
    }

    private func updateBendDrag(to point: NSPoint) {
        guard var drag = keyDrag, let id = drag.bendKeyID,
              let midpoint = drag.lane.curve.midpoint(after: id),
              let layerID = drag.original.layerID(of: drag.lane.clip.id) else { return }
        var clip = drag.lane.clip
        var curve = drag.lane.curve
        let value = drag.lane.value(at: drag.lane.y(at: midpoint.value) + point.y - drag.initial.y)
        if point.y != drag.initial.y { curve.adjustMidpoint(after: id, handleValue: value) }
        clip.setCurve(curve)
        drag.changed = true
        do { drag.draft = try drag.original.updating(clip, layerID: layerID, duration: duration) }
        catch { drag.draft = nil; onError?(error) }
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
        if original.changed { updateKeyDrag(to: point) }
        guard let drag = keyDrag else { return }
        keyDrag = nil
        let parameter = drag.lane.curve.parameter
        if drag.bendKeyID != nil {
            if let draft = drag.draft, draft != drag.original { onImageCommit?(draft, drag.lane.clip.id) }
            else if drag.changed { restoreKeyPreview(drag) }
            selectGraph(parameter)
        } else if let key = drag.key {
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
            } else if let layerID = visuals.layerID(of: clip.id) {
                let keyID = clip.setKey(parameter, at: time, value: drag.lane.value(at: drag.initial.y))
                do {
                    let updated = try visuals.updating(clip, layerID: layerID, duration: duration)
                    onImageCommit?(updated, clip.id)
                    selectGraph(parameter, key: keyID)
                } catch { onError?(error) }
            }
        }
        needsDisplay = true
    }

}

@MainActor
private final class LayerNameField: NSTextField, NSTextFieldDelegate {
    var onFinish: ((String?) -> Void)?
    init(string: String) {
        super.init(frame: .zero); stringValue = string; delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidEndEditing(_ obj: Notification) { finish(stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { finish(nil); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { finish(stringValue); return true }
        return false
    }
    private func finish(_ value: String?) { let action = onFinish; onFinish = nil; action?(value) }
}
