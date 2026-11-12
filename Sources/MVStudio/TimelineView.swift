import AppKit

@MainActor
final class TimelineView: NSView {
    var visualMode = false { didSet { hoverPoint = nil; cancelDrag(); updateGraphLayout(); setAccessibilityLabel(visualMode ? "画像タイムライン" : "歌詞タイムライン"); needsDisplay = true } }
    var visuals = VisualTrack() {
        didSet {
            layerParameters = Dictionary(uniqueKeysWithValues: visuals.layers.map { layer in
                let used = Set(layer.clips.flatMap { $0.automationParameters })
                return (layer.slot, ImageParameter.allCases.filter { used.contains($0) })
            })
            updateGraphLayout()
        }
    }
    var audioFeatures: AudioFeatures? { didSet { needsDisplay = true } }
    var sceneSettings = SceneSettings() { didSet { needsDisplay = true } }
    var automationPreview: VisualTrack? { didSet { needsDisplay = true } }
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
    var heights = TimelineHeights() { didSet { updateRowLayout() } }
    var onHeightCommit: (() -> Void)?
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
    var selectedSlot = 1 { didSet { needsDisplay = true } }
    var onImageSelect: ((UUID?, Int) -> Void)?
    var onImagePreview: ((VisualTrack) -> Void)?
    var onImageCommit: ((VisualTrack, UUID) -> Void)?
    var onDropImage: ((URL, Int, Double) -> Void)?
    private var imageDrag: ImageDrag?
    private var dropGeometry: TimelineGeometry?
    private var dropCandidate: (slot: Int, start: Double, end: Double)?
    private struct ImageDrag {
        let original: VisualTrack
        let geometry: TimelineGeometry
        let id: UUID
        let part: TimelineDragPart
        let initialX: Double
        var draft: VisualTrack
        var hasDragged = false
        var targetSlot: Int?
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
        drag?.geometry ?? keyDrag?.geometry ?? imageDrag?.geometry ?? dropGeometry ?? scrubGeometry
    }

    func followPlayhead() { manualOrigin = nil }

    static let gutter = 78.0
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
        isEnabled && rowResize == nil && frozenGeometry == nil && automationPreview == nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                                       owner: self, userInfo: nil))
        identifier = NSUserInterfaceItemIdentifier("placement.timeline")
        toolTip = "Shift＋ホイールで横スクロール、⌘＋ホイールで拡大・縮小、Option＋ホイールで再生位置を移動。本体を左右で時刻移動、画像本体を上下でレイヤー移動。左右端で開始・終了を調整。行の下の境界線で高さを調整。空白や目盛りでシーク。Escで取り消し。"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("歌詞タイムライン")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 1).setFill(); bounds.fill()
        if visualMode { drawImages() }
        else { drawLyrics() }
        drawRowBoundaries()
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

    private func imageHit(at point: NSPoint, slot: Int) -> ClipHit? {
        guard graphViewport.contains(point), let layer = visuals.layers.first(where: { $0.slot == slot }) else { return nil }
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
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if hoverPoint != nil {
            hoverPoint = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
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
        if rowResize != nil {
            updateRowResize(with: event)
            if let resize = rowResize {
                rowResize = nil
                if heights[resize.row] != resize.height {
                    heights[resize.row] = resize.height
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
        if visualMode, onImageCommit != nil,
           let hit = graphKey(at: point, in: graphLanes(in: visuals)),
           window?.makeFirstResponder(self) != false {
            if selectedImageID != hit.lane.clip.id {
                selectedSlot = visuals.slot(of: hit.lane.clip.id) ?? selectedSlot
                selectedImageID = hit.lane.clip.id
                onImageSelect?(hit.lane.clip.id, selectedSlot)
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
        if canRemoveAutomation, let label = graphLabel(at: point) {
            let menu = NSMenu()
            let item = menu.addItem(withTitle: "レーンを削除（キーと音楽同期）", action: #selector(removeAutomationLane(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = label.target
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
        guard visualMode, canEditClips, let slot = visuals.slot(of: target.clipID),
              var clip = visuals.clip(target.clipID), var curve = clip.curve(target.parameter),
              let index = curve.keys.firstIndex(where: { $0.id == target.keyID }) else { return }
        if delete { clip.removeKey(target.keyID, parameter: target.parameter) }
        else {
            guard curve.keys[index].incomingInterpolation != interpolation else { return }
            curve.keys[index].interpolation = interpolation == .single ? nil : interpolation
            clip.setCurve(curve)
        }
        do {
            let updated = try visuals.updating(clip, slot: slot, duration: duration)
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
            guard let slot = slot(at: point), let hit = imageHit(at: point, slot: slot),
                  window?.makeFirstResponder(self) != false else { return false }
            selectVisualClip(hit.id, slot: slot)
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

    private func selectVisualClip(_ id: UUID, slot: Int) {
        selectedSlot = slot
        selectedImageID = id
        if selectedKeyID != nil { selectGraph(selectedParameter) }
        onImageSelect?(id, slot)
    }

    @objc private func performClipCommand(_ item: NSMenuItem) {
        guard let command = item.representedObject as? ClipEditCommand,
              canPerformClipCommand?(command) == true else { return }
        onClipCommand?(command)
    }

    private var canRemoveAutomation: Bool {
        visualMode && canEditClips && onImageCommit != nil
    }

    @objc private func removeAutomationLane(_ item: NSMenuItem) {
        guard canRemoveAutomation, let target = item.representedObject as? GraphTarget,
              var clip = visuals.clip(target.clipID), clip.displayCurve(target.parameter) != nil,
              let slot = visuals.slot(of: clip.id) else { return }
        clip.removeAudioAndKeys(target.parameter)
        do {
            let updated = try visuals.updating(clip, slot: slot, duration: duration)
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
        guard visualMode, expandedLayerSlots.contains(selectedSlot), let parameter = selectedParameter,
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

    private func automationParameters(in slot: Int) -> [ImageParameter] {
        guard expandedLayerSlots.contains(slot) else { return [] }
        return layerParameters[slot] ?? []
    }

    private func rowHeight(_ row: TimelineHeights.Row) -> Double {
        if let resize = rowResize, resize.row == row { return resize.height }
        return heights[row]
    }

    private func height(of slot: Int) -> Double {
        automationParameters(in: slot).reduce(rowHeight(.visual(slot))) { $0 + rowHeight(.automation(slot, $1)) }
    }

    private var contentHeight: Double { (1...3).reduce(0) { $0 + height(of: $1) } }
    private var rowsBottom: Double { min(bounds.height - 24, rowsTop + contentHeight - imageScroll) }
    private var maximumRowScroll: Double {
        let bottom = visualMode ? rowsTop + contentHeight : lyricBoundaryY + lyricScroll
        return max(0, bottom - (bounds.height - 24))
    }

    private var rowBoundaries: [RowBoundary] {
        guard visualMode else { return [RowBoundary(row: .lyrics, y: lyricBoundaryY)] }
        return (1...3).flatMap { slot -> [RowBoundary] in
            let image = RowBoundary(row: .visual(slot), y: rowY(slot) + rowHeight(.visual(slot)))
            return [image] + automationParameters(in: slot).enumerated().map { index, parameter in
                let row = TimelineHeights.Row.automation(slot, parameter)
                return RowBoundary(row: row, y: graphY(slot: slot, index: index) - graphPadding + rowHeight(row))
            }
        }
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
        let range = resize.row.range
        resize.height = min(range.upperBound, max(range.lowerBound, resize.initialHeight + point.y - resize.initialY))
        rowResize = resize
        rowScroll = resize.initialScroll
        hoverPoint = point
        updateRowLayout()
    }

    func selectGraph(_ parameter: ImageParameter?, key: UUID? = nil, reveal: Bool = false) {
        selectedParameter = parameter
        selectedKeyID = key
        if reveal, let parameter, let slot = selectedImageID.flatMap({ visuals.slot(of: $0) }),
           let index = automationParameters(in: slot).firstIndex(of: parameter) {
            revealRows(from: graphY(slot: slot, index: index), height: rowHeight(.automation(slot, parameter)) - graphPadding)
        }
        onGraphSelection?()
        needsDisplay = true
    }

    func resetGraphDisclosure() {
        expandedLayerSlots.removeAll()
        imageScroll = 0
        lyricScroll = 0
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
        let firstLaneHeight = automationParameters(in: slot).first.map { rowHeight(.automation(slot, $0)) } ?? 0
        revealRows(from: rowY(slot), height: rowHeight(.visual(slot)) + firstLaneHeight)
    }

    private func revealRows(from top: Double, height: Double) {
        if top + height > rowsBottom { rowScroll += top + height - rowsBottom }
        if top < rowsTop { rowScroll += top - rowsTop }
        updateRowLayout()
    }

    private func updateRowLayout() {
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRowLayout()
    }

    override func scrollWheel(with event: NSEvent) {
        guard rowResize == nil else { return }
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

    private func slot(at point: NSPoint) -> Int? {
        guard point.y >= rowsTop, point.y < rowsBottom else { return nil }
        return (1...3).first { slot in
            let y = rowY(slot)
            return point.y >= y && point.y < y + height(of: slot)
        }
    }

    private func rowY(_ slot: Int) -> Double {
        rowsTop - imageScroll + (1...3).filter { $0 > slot }.reduce(0) { $0 + height(of: $1) }
    }

    private func disclosureRect(for slot: Int) -> NSRect {
        let rowHeight = rowHeight(.visual(slot))
        let height = min(29, rowHeight - 6)
        return NSRect(x: 55, y: rowY(slot) + (rowHeight - height) / 2, width: 22, height: height)
    }

    private func graphY(slot: Int, index: Int) -> Double {
        automationParameters(in: slot).prefix(index).reduce(rowY(slot) + rowHeight(.visual(slot)) + graphPadding) {
            $0 + rowHeight(.automation(slot, $1))
        }
    }

    private func graphLanes(in displayed: VisualTrack) -> [GraphLane] {
        displayed.layers.flatMap { layer in
            let parameters = automationParameters(in: layer.slot)
            guard !parameters.isEmpty else { return [GraphLane]() }
            return layer.clips.filter { $0.end >= geometry.origin && $0.start <= geometry.origin + geometry.span }.flatMap { clip in
                parameters.enumerated().compactMap { index, parameter in
                    guard let curve = clip.displayCurve(parameter) else { return nil }
                    let left = x(at: clip.start)
                    let rect = NSRect(x: left, y: graphY(slot: layer.slot, index: index),
                                      width: x(at: clip.end) - left, height: rowHeight(.automation(layer.slot, parameter)) - 2 * graphPadding)
                    return GraphLane(clip: clip, curve: curve, rect: rect)
                }
            }
        }
    }
    private func imageRect(_ clip: VisualClip, slot: Int) -> NSRect {
        NSRect(x: x(at: clip.start), y: rowY(slot) + 3, width: x(at: clip.end) - x(at: clip.start), height: rowHeight(.visual(slot)) - 7)
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
        let selectedLayer = selectedImageID.flatMap { displayed.slot(of: $0) }
        for slot in 1...3 {
            if slot == (imageDrag?.targetSlot ?? selectedSlot) {
                NSColor.white.withAlphaComponent(0.04).setFill()
                NSRect(x: 0, y: rowY(slot), width: bounds.width, height: height(of: slot)).fill()
            }
            let rowCenter = rowY(slot) + rowHeight(.visual(slot)) / 2
            label("画像\(slot)" + (slot == 3 ? " 前" : slot == 1 ? " 後" : ""),
                  rect: NSRect(x: 5, y: rowCenter - 8, width: 50, height: 16), color: .lightGray, size: 11)
            if layerParameters[slot]?.isEmpty == false {
                let button = disclosureRect(for: slot)
                label(expandedLayerSlots.contains(slot) ? "v" : ">",
                      rect: NSRect(x: button.minX + 6, y: button.midY - 7.5, width: 16, height: 15),
                      color: .white.withAlphaComponent(0.45), size: 12)
            }
            let clip = selectedLayer == slot ? selectedClip : nil
            for (index, parameter) in automationParameters(in: slot).enumerated() {
                let color: NSColor = clip != nil && parameter == selectedParameter ? .cyan : .lightGray
                let y = graphY(slot: slot, index: index)
                label(parameter.title, rect: NSRect(x: 5, y: y, width: 73, height: 16), color: color, size: 11)
                if showsGraphRange(slot: slot, parameter: parameter), let curve = clip?.displayCurve(parameter) {
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
                let clipRect = imageRect(clip, slot: layer.slot)
                let rect = clipRect.intersection(clipBounds)
                guard !rect.isEmpty else { continue }
                let missing = missingAssets.contains(clip.assetID)
                (missing ? NSColor.systemRed : NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.57, alpha: 1)).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 0), xRadius: 4, yRadius: 4).fill()
                if clip.id == selectedImageID { NSColor.cyan.setStroke(); NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).stroke() }
                let title = (missing ? "⚠ " : "") + (clip.content.sourceIn == nil ? "" : "▶ ") + (displayed.asset(clip.assetID)?.name ?? "不明")
                drawClipLabels(title, timing: clipTiming(start: clip.start, end: clip.end), in: clipRect, visible: rect)
                drawClipGrips(in: clipRect, visible: rect)
            }
        }
        let highlight = highlightedKey(in: lanes)
        if highlight == nil, canEditClips, let point = hoverPoint, let slot = slot(at: point) {
            drawTrimHighlight(imageHit(at: point, slot: slot))
        }
        let bendHighlight = highlightedBend(in: lanes)
        for lane in lanes {
            let bendID = bendHighlight.flatMap {
                $0.lane.clip.id == lane.clip.id && $0.lane.curve.parameter == lane.curve.parameter ? $0.key.id : nil
            }
            drawGraph(lane, clippedTo: clipBounds, excluding: highlight?.key.id, highlightedBend: bendID)
        }
        if let drag = imageDrag, drag.error != nil, let slot = drag.targetSlot, let clip = drag.original.clip(drag.id) {
            NSColor.systemRed.setStroke()
            let outline = NSBezierPath(roundedRect: imageRect(clip, slot: slot).insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            outline.lineWidth = 2; outline.stroke()
        }
        if let candidate = dropCandidate {
            NSColor.cyan.withAlphaComponent(0.35).setFill()
            NSRect(x: x(at: candidate.start), y: rowY(candidate.slot) + 3, width: x(at: candidate.end) - x(at: candidate.start),
                   height: rowHeight(.visual(candidate.slot)) - 7).fill()
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
        let hint = !expandedLayerSlots.isEmpty ? "グラフ：クリックで点を追加、○を上下でカーブ・幅・周期を調整、Deleteで点を削除　｜　上下スクロール　Esc：取消" : "本体：左右で時刻移動・上下で段移動　端：開始/終了　Esc：取消"
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
                selectVisualClip(hit.id, slot: slot)
                onBeginEdit?()
                imageDrag = ImageDrag(original: visuals, geometry: frozen, id: hit.id, part: hit.part, initialX: point.x, draft: visuals, targetSlot: slot, error: nil)
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
        guard objects.count == 1, let url = objects.first, ["png", "jpg", "jpeg", "tif", "tiff", "mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard visualMode, isEnabled, imageDrag == nil, keyDrag == nil, drag == nil, rowResize == nil else { return [] }
        dropGeometry = geometry
        return draggingUpdated(sender)
    }
    func fileDrop(at point: NSPoint, pasteboard: NSPasteboard) throws -> (url: URL, slot: Int, start: Double, end: Double) {
        guard visualMode, isEnabled, imageDrag == nil, keyDrag == nil, drag == nil, rowResize == nil, let url = droppedURL(pasteboard),
              point.x >= Self.gutter + TimelineGeometry.inset, point.x <= bounds.width - TimelineGeometry.inset,
              let slot = slot(at: point), point.y < rowY(slot) + rowHeight(.visual(slot)) else { throw StudioError.message("画像・動画を1ファイルずつ、配置可能な素材行の空白にドロップしてください。") }
        let range = try visuals.placement(at: geometry.time(at: point.x - Self.gutter), slot: slot, duration: duration, grid: snapGrid)
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
            onError?(StudioError.message("画像・動画を1ファイルずつ、配置可能な素材行の空白にドロップしてください。")); draggingExited(sender); return false
        }
        onBeginEdit?()
        onDropImage?(url, candidate.slot, candidate.start)
        draggingExited(sender)
        return true
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
              let slot = slot(at: point), let clip = visuals.clip(selectedImageID),
              visuals.slot(of: clip.id) == slot else { return nil }
        for (index, parameter) in automationParameters(in: slot).enumerated() {
            let localY = point.y - graphY(slot: slot, index: index)
            if (0...(rowHeight(.automation(slot, parameter)) - 2 * graphPadding)).contains(localY), clip.displayCurve(parameter) != nil {
                return (GraphTarget(clipID: clip.id, parameter: parameter), localY)
            }
        }
        return nil
    }

    private func showsGraphRange(slot: Int, parameter: ImageParameter) -> Bool {
        rowHeight(.automation(slot, parameter)) >= 54
    }

    private func graphMouseDown(at point: NSPoint, geometry: TimelineGeometry) -> Bool {
        if let label = graphLabel(at: point) {
            let parameter = label.target.parameter
            selectGraph(parameter, key: selectedParameter == parameter ? selectedKeyID : nil)
            if let slot = visuals.slot(of: label.target.clipID),
               showsGraphRange(slot: slot, parameter: parameter), label.localY >= 17 {
                onGraphRangeEdit?(label.localY < 32)
            }
            return true
        }
        guard graphViewport.contains(point) else { return false }
        let lanes = graphLanes(in: visuals)
        let hit = graphKey(at: point, in: lanes)
        let bend = hit == nil ? graphBend(at: point, in: lanes) : nil
        guard let lane = hit?.lane ?? bend?.lane ?? lanes.first(where: { $0.rect.contains(point) }),
              let slot = visuals.slot(of: lane.clip.id) else { return false }
        let key = hit?.key
        if selectedImageID != lane.clip.id {
            selectedSlot = slot
            selectedImageID = lane.clip.id
            onImageSelect?(lane.clip.id, slot)
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

    private func updateBendDrag(to point: NSPoint) {
        guard var drag = keyDrag, let id = drag.bendKeyID,
              let midpoint = drag.lane.curve.midpoint(after: id),
              let slot = drag.original.slot(of: drag.lane.clip.id) else { return }
        var clip = drag.lane.clip
        var curve = drag.lane.curve
        let value = drag.lane.value(at: drag.lane.y(at: midpoint.value) + point.y - drag.initial.y)
        if point.y != drag.initial.y { curve.adjustMidpoint(after: id, handleValue: value) }
        clip.setCurve(curve)
        drag.changed = true
        do { drag.draft = try drag.original.updating(clip, slot: slot, duration: duration) }
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
            } else if let slot = visuals.slot(of: clip.id) {
                let keyID = clip.setKey(parameter, at: time, value: drag.lane.value(at: drag.initial.y))
                do {
                    let updated = try visuals.updating(clip, slot: slot, duration: duration)
                    onImageCommit?(updated, clip.id)
                    selectGraph(parameter, key: keyID)
                } catch { onError?(error) }
            }
        }
        needsDisplay = true
    }
}
