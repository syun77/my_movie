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
    var onWholeSongChange: ((Bool) -> Void)?
    var onModeChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    private let tabs = NSSegmentedControl(labels: ["歌詞", "画像・演出", "スペクトラム"], trackingMode: .selectOne, target: nil, action: nil)
    private let zoom = NSSlider(value: TimelineDisplaySettings.defaultSpan, minValue: TimelineDisplaySettings.spanRange.lowerBound, maxValue: TimelineDisplaySettings.spanRange.upperBound, target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "12.0秒")
    private let wholeSong = NSButton(checkboxWithTitle: "曲全体", target: nil, action: nil)
    private var available = true
    private var wheelZoomTimer: Timer?
    private let wheelZoomDuration = 0.2
    let inspector = NSStackView()
    private var heightConstraint: NSLayoutConstraint!
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
    var snapGrid = TimelineSnapGrid() { didSet { lyrics.snapGrid = snapGrid; images.snapGrid = snapGrid } }

    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8; view = root
        _ = lyrics.view; _ = images.view
        images.timeline = timeline
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
        let header = NSStackView(views: [NSTextField(labelWithString: "表示範囲"), zoom, zoomLabel, wholeSong]); header.spacing = 12
        for child in [header, timeline] { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        heightConstraint = timeline.heightAnchor.constraint(equalToConstant: 210); heightConstraint.isActive = true
        inspector.orientation = .vertical
        inspector.alignment = .leading
        inspector.spacing = 12
        inspector.addArrangedSubview(tabs)
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
            heightConstraint.constant = imageMode ? 210 : 112
        }
        let child: NSView
        switch tab {
        case .lyrics: child = lyrics.view
        case .images: child = images.view
        case .spectrum: child = spectrum.view
        }
        inspector.arrangedSubviews.last(where: { $0 !== tabs })?.removeFromSuperview()
        inspector.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
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
        zoom.isEnabled = available && !showsWholeSong
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
