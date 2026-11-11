import AppKit

@MainActor
final class PlacementEditor: NSViewController {
    enum Tab: Int {
        case lyrics, images, spectrum
    }

    let lyrics = LyricsEditor()
    let images = ImageEditor()
    let spectrum = SpectrumEditor()
    var timeline: TimelineView { lyrics.timeline }
    var onVisibleSpanChange: ((Double) -> Void)?
    var onSnapDivisionChange: ((TimelineSnapDivision) -> Void)?
    var onWholeSongChange: ((Bool) -> Void)?
    var onModeChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    private let tabs = NSSegmentedControl(labels: ["歌詞", "画像・演出", "スペクトラム"], trackingMode: .selectOne, target: nil, action: nil)
    private let zoom = NSSlider(value: TimelineDisplaySettings.defaultSpan, minValue: TimelineDisplaySettings.spanRange.lowerBound, maxValue: TimelineDisplaySettings.spanRange.upperBound, target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "12.0秒")
    private let wholeSong = NSButton(checkboxWithTitle: "曲全体", target: nil, action: nil)
    private let snapDivision = NSPopUpButton()
    private var available = true
    private var wheelZoomTimer: Timer?
    private let wheelZoomDuration = 0.2
    let inspector = NSStackView()
    private let inspectorScroll = NSScrollView()
    private let inspectorDocument = InspectorDocumentView()
    private static let minimumTimelineHeight = CGFloat(TimelineHeights.viewportRange.lowerBound)
    private var preferredTimelineHeight: NSLayoutConstraint!
    var timelineHeights: TimelineHeights { timeline.heights }
    var onTimelineHeightsCommit: (() -> Void)?
    private(set) var selectedTab: Tab = .lyrics
    var imageMode: Bool { timeline.imageMode }
    var visibleSpan = TimelineDisplaySettings.defaultSpan {
        didSet { updateDisplayRange() }
    }
    var showsWholeSong = false {
        didSet {
            if showsWholeSong { timeline.followPlayhead() }
            updateDisplayRange()
        }
    }
    var currentTime = 0.0 { didSet { lyrics.currentTime = currentTime; images.currentTime = currentTime } }
    var duration = 0.0 { didSet { lyrics.duration = duration; images.duration = duration; updateDisplayRange() } }
    var snapGrid = TimelineSnapGrid() {
        didSet {
            lyrics.snapGrid = snapGrid
            images.snapGrid = snapGrid
            snapDivision.selectItem(withTag: snapGrid.division.rawValue)
        }
    }

    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8; view = root
        _ = lyrics.view; _ = images.view
        images.timeline = timeline
        timeline.canPerformClipCommand = { [weak self] command in
            self?.canEditClip(command, pasteboard: .general) == true
        }
        timeline.onClipCommand = { [weak self] command in
            self?.editClip(command, pasteboard: .general)
        }
        timeline.onHeightCommit = { [weak self] in self?.onTimelineHeightsCommit?() }
        timeline.onWheelZoom = { [weak self] steps in self?.zoomTimeline(by: steps) }
        timeline.onError = { [weak self] error in
            guard let self else { return }
            if self.imageMode { self.images.report(error) }
            self.onError?(error.localizedDescription)
        }
        tabs.target = self; tabs.action = #selector(changePlacementMode); tabs.selectedSegment = 0
        tabs.identifier = NSUserInterfaceItemIdentifier("placement.mode")
        zoom.target = self; zoom.action = #selector(changeZoom)
        wholeSong.target = self; wholeSong.action = #selector(changeWholeSong)
        wholeSong.identifier = NSUserInterfaceItemIdentifier("timeline.wholeSong")
        zoom.widthAnchor.constraint(equalToConstant: 160).isActive = true
        zoomLabel.widthAnchor.constraint(equalToConstant: 85).isActive = true
        for division in TimelineSnapDivision.allCases {
            snapDivision.addItem(withTitle: division.title)
            snapDivision.lastItem?.tag = division.rawValue
        }
        snapDivision.selectItem(withTag: snapGrid.division.rawValue)
        snapDivision.identifier = NSUserInterfaceItemIdentifier("timeline.snapDivision")
        snapDivision.setAccessibilityLabel("スナップ")
        snapDivision.target = self; snapDivision.action = #selector(changeSnapDivision)
        let header = NSStackView(views: [
            NSTextField(labelWithString: "表示範囲"), zoom, zoomLabel, wholeSong,
            NSTextField(labelWithString: "スナップ"), snapDivision
        ])
        header.spacing = 12
        for child in [header, timeline] { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        timeline.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumTimelineHeight).isActive = true
        preferredTimelineHeight = timeline.heightAnchor.constraint(equalToConstant: Self.minimumTimelineHeight)
        preferredTimelineHeight.priority = NSLayoutConstraint.Priority(749)
        preferredTimelineHeight.isActive = true
        inspector.orientation = .vertical
        inspector.alignment = .leading
        inspector.spacing = 12
        inspector.addArrangedSubview(tabs)
        inspector.addArrangedSubview(inspectorScroll)
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.scrollerStyle = .overlay
        inspectorScroll.drawsBackground = false
        inspectorScroll.documentView = inspectorDocument
        inspectorDocument.translatesAutoresizingMaskIntoConstraints = false
        let clip = inspectorScroll.contentView
        NSLayoutConstraint.activate([
            inspectorScroll.widthAnchor.constraint(equalTo: inspector.widthAnchor),
            inspectorDocument.topAnchor.constraint(equalTo: clip.topAnchor),
            inspectorDocument.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            inspectorDocument.widthAnchor.constraint(equalTo: clip.widthAnchor)
        ])
        restoreTab(.lyrics)
        updateDisplayRange()
    }

    func restoreTab(_ tab: Tab) {
        cancelTimelineEdit()
        if selectedTab == .spectrum && tab != .spectrum { spectrum.endColorEditing() }
        selectedTab = tab
        tabs.selectedSegment = tab.rawValue
        if tab != .spectrum {
            timeline.imageMode = tab == .images
            updatePreferredTimelineHeight()
        }
        let child: NSView
        switch tab {
        case .lyrics: child = lyrics.view
        case .images: child = images.view
        case .spectrum: child = spectrum.view
        }
        inspectorDocument.subviews.first?.removeFromSuperview()
        child.translatesAutoresizingMaskIntoConstraints = false
        inspectorDocument.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: inspectorDocument.topAnchor),
            child.bottomAnchor.constraint(equalTo: inspectorDocument.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: inspectorDocument.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: inspectorDocument.trailingAnchor)
        ])
        inspectorScroll.contentView.scroll(to: .zero)
        inspectorScroll.reflectScrolledClipView(inspectorScroll.contentView)
    }

    func resizeTimeline(to height: CGFloat) {
        let range = TimelineHeights.viewportRange
        preferredTimelineHeight.constant = min(CGFloat(range.upperBound), max(Self.minimumTimelineHeight, height))
    }

    func commitTimelineHeight(from initialHeight: CGFloat) {
        let height = preferredTimelineHeight.constant
        guard height != initialHeight else {
            updatePreferredTimelineHeight()
            return
        }
        guard Double(height) != timeline.heights.viewport else { return }
        timeline.heights.viewport = Double(height)
        onTimelineHeightsCommit?()
    }

    func restoreTimelineHeights(_ heights: TimelineHeights) {
        timeline.cancelDrag()
        timeline.heights = heights
        updatePreferredTimelineHeight()
    }

    private func updatePreferredTimelineHeight() {
        preferredTimelineHeight.constant = timeline.heights.viewport.map { CGFloat($0) }
            ?? (imageMode ? 210 : Self.minimumTimelineHeight)
    }

    @objc private func changeSnapDivision() {
        guard let item = snapDivision.selectedItem, let division = TimelineSnapDivision(rawValue: item.tag),
              division != snapGrid.division else { return }
        snapGrid.division = division
        onSnapDivisionChange?(division)
    }

    @objc private func changePlacementMode() {
        guard let tab = Tab(rawValue: tabs.selectedSegment) else { return }
        timeline.cancelDrag()
        guard finishEditing() else {
            tabs.selectedSegment = selectedTab.rawValue
            onError?("入力を確定し、開始・終了を正しい区間にしてください。")
            return
        }
        restoreTab(tab)
        if tab != .spectrum { onModeChange?(imageMode) }
    }
    private func updateDisplayRange() {
        wheelZoomTimer?.invalidate()
        wheelZoomTimer = nil
        timeline.cancelDrag()
        let span = showsWholeSong && duration.isFinite && duration > 0 ? duration : visibleSpan
        displaySpan(span)
        zoom.isEnabled = available && !showsWholeSong
        wholeSong.state = showsWholeSong ? .on : .off
    }

    private func displaySpan(_ span: Double) {
        timeline.visibleSpan = span
        zoom.doubleValue = showsWholeSong ? visibleSpan : span
        zoomLabel.stringValue = String(format: "%.1f秒", span)
    }
    @objc private func changeWholeSong() {
        setWholeSong(wholeSong.state == .on)
    }

    private func setWholeSong(_ value: Bool) {
        showsWholeSong = value
        onWholeSongChange?(value)
    }

    @objc private func changeZoom() { setFixedSpan(zoom.doubleValue) }

    private func setFixedSpan(_ value: Double) {
        visibleSpan = value
        onVisibleSpanChange?(value)
    }

    private func zoomTimeline(by steps: Double) {
        guard available, !showsWholeSong || steps > 0 else { return }
        let range = TimelineDisplaySettings.spanRange
        let start = timeline.visibleSpan
        let previousTarget = showsWholeSong ? start : visibleSpan
        let requested = previousTarget * pow(1.15, -steps)
        let next = min(range.upperBound, max(range.lowerBound, requested))
        guard showsWholeSong ? next < start : next != previousTarget else { return }
        if showsWholeSong { setWholeSong(false) }
        setFixedSpan(next)
        guard start != next else { return }

        displaySpan(start)
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let progress = min(1, elapsed / self.wheelZoomDuration)
                let remaining = 1 - progress
                self.displaySpan(next + (start - next) * remaining * remaining * remaining)
                if progress == 1 {
                    timer.invalidate()
                    self.wheelZoomTimer = nil
                }
            }
        }
        wheelZoomTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func setAvailable(hasAudio: Bool, isBusy: Bool) {
        available = hasAudio && !isBusy
        lyrics.setAvailable(available)
        images.setAvailable(available)
        tabs.isEnabled = !isBusy
        spectrum.setAvailable(!isBusy, hasAudio: hasAudio)
        wholeSong.isEnabled = available
        snapDivision.isEnabled = !isBusy
        zoom.isEnabled = available && !showsWholeSong
    }

    private var selectedLyric: LyricClip? {
        lyrics.track.clips.first { $0.id == timeline.selectedID }
    }

    private var selectedImage: ImageClip? { images.track.clip(timeline.selectedImageID) }

    func canEditClip(_ command: ClipEditCommand, pasteboard: NSPasteboard) -> Bool {
        guard available, timeline.canEditClips else { return false }
        if command == .paste {
            return pasteSource(from: pasteboard) != nil
        }
        return imageMode ? selectedImage != nil : selectedLyric != nil
    }

    func editClip(_ command: ClipEditCommand, pasteboard: NSPasteboard) {
        guard available, timeline.canEditClips else { return }
        do {
            switch command {
            case .copy, .cut:
                if try copySelection(to: pasteboard), command == .cut { try removeSelection() }
            case .delete:
                try removeSelection()
            case .paste:
                switch pasteSource(from: pasteboard) {
                case let .lyrics(clip):
                    try insertLyricCopy(clip, at: timeline.currentTime)
                case let .image(clip, url):
                    guard let projectURL = images.projectURL else { return }
                    var track = images.track
                    var source = clip
                    source.assetID = track.register(url: url, projectURL: projectURL)
                    try insertImageCopy(source, in: track, at: timeline.currentTime, slot: timeline.selectedSlot)
                case nil: break
                }
            case .duplicate:
                if imageMode {
                    guard let clip = selectedImage, let slot = images.track.slot(of: clip.id) else { return }
                    try insertImageCopy(clip, in: images.track, at: clip.end, slot: slot)
                } else if let clip = selectedLyric {
                    try insertLyricCopy(clip, at: clip.end)
                }
            }
        } catch { timeline.onError?(error) }
    }

    private func pasteSource(from pasteboard: NSPasteboard) -> ClipClipboard? {
        let source = ClipClipboard.read(from: pasteboard)
        switch source {
        case .lyrics where !imageMode: return source
        case let .image(_, url) where imageMode && images.projectURL != nil && url.isFileURL: return source
        default: return nil
        }
    }

    private func copySelection(to pasteboard: NSPasteboard) throws -> Bool {
        if imageMode {
            guard let clip = selectedImage, let asset = images.track.asset(clip.assetID) else { return false }
            let url: URL
            if let projectURL = images.projectURL {
                url = asset.reference.resolve(projectURL: projectURL)
            } else {
                guard !asset.reference.relative else { return false }
                url = URL(fileURLWithPath: asset.reference.path)
            }
            try ClipClipboard.image(clip, assetURL: url).write(to: pasteboard)
        } else {
            guard let clip = selectedLyric else { return false }
            try ClipClipboard.lyrics(clip).write(to: pasteboard)
        }
        return true
    }

    private func removeSelection() throws {
        if imageMode {
            if let clip = selectedImage { images.commit(images.track.removingClip(id: clip.id)) }
        } else if let clip = selectedLyric {
            let remainder = try lyrics.track.removing(id: clip.id, duration: duration)
            lyrics.commit(remainder, selectedID: nil)
        }
    }

    private func insertLyricCopy(_ source: LyricClip, at time: Double) throws {
        let clip = LyricClip(start: time, end: time + (source.end - source.start), text: source.text)
        let track = try lyrics.track.inserting(clip, duration: duration)
        lyrics.commit(track, selectedID: clip.id)
    }

    private func insertImageCopy(_ source: ImageClip, in track: ImageTrack, at time: Double, slot: Int) throws {
        var clip = source
        clip.id = UUID()
        clip.start = time
        clip.end = time + (source.end - source.start)
        for curve in clip.curves.indices {
            for key in clip.curves[curve].keys.indices {
                clip.curves[curve].keys[key].id = UUID()
            }
        }
        let updated = try track.inserting(clip, slot: slot, duration: duration)
        images.commit(updated, selectedID: clip.id)
    }

    func cancelTimelineEdit() {
        timeline.cancelDrag()
        images.cancelValueDrag()
        for field in DragValueField.fields(in: inspector) { field.cancelNumberDrag() }
    }
    func finishEditing() -> Bool {
        if selectedTab == .spectrum { return spectrum.finishEditing() }
        return imageMode ? images.finishEditing() : lyrics.finishEditing()
    }
}


private final class InspectorDocumentView: NSView {
    override var isFlipped: Bool { true }
}
