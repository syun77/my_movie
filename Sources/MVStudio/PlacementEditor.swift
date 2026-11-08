import AppKit

@MainActor
final class PlacementEditor: NSViewController {
    let lyrics = LyricsEditor()
    let images = ImageEditor()
    var timeline: TimelineView { lyrics.timeline }
    var onVisibleSpanChange: ((Double) -> Void)?
    var onWholeSongChange: ((Bool) -> Void)?
    var onModeChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    private let tabs = NSSegmentedControl(labels: ["歌詞", "画像・演出"], trackingMode: .selectOne, target: nil, action: nil)
    private let zoom = NSSlider(value: TimelineDisplaySettings.defaultSpan, minValue: TimelineDisplaySettings.spanRange.lowerBound, maxValue: TimelineDisplaySettings.spanRange.upperBound, target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "12.0秒")
    private let wholeSong = NSButton(checkboxWithTitle: "曲全体", target: nil, action: nil)
    private var available = true
    private let details = NSView()
    private var detailConstraints: [NSLayoutConstraint] = []
    private var heightConstraint: NSLayoutConstraint!
    private(set) var imageMode = false
    var visibleSpan = TimelineDisplaySettings.defaultSpan {
        didSet { updateDisplayRange() }
    }
    var showsWholeSong = false { didSet { updateDisplayRange() } }
    var currentTime = 0.0 { didSet { lyrics.currentTime = currentTime; images.currentTime = currentTime } }
    var duration = 0.0 { didSet { lyrics.duration = duration; images.duration = duration; updateDisplayRange() } }
    var snapGrid = TimelineSnapGrid() { didSet { lyrics.snapGrid = snapGrid; images.snapGrid = snapGrid } }

    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8; view = root
        _ = lyrics.view; _ = images.view
        images.timeline = timeline
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
        let header = NSStackView(views: [tabs, NSTextField(labelWithString: "表示範囲"), zoom, zoomLabel, wholeSong]); header.spacing = 12
        for child in [header, timeline, details] { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        heightConstraint = timeline.heightAnchor.constraint(equalToConstant: 210); heightConstraint.isActive = true
        details.heightAnchor.constraint(equalToConstant: 205).isActive = true
        showMode(false)
        updateDisplayRange()
    }
    func restoreMode(_ value: Bool) { showMode(value) }
    private func showMode(_ value: Bool) {
        timeline.cancelDrag()
        heightConstraint.constant = value ? 210 : 112
        imageMode = value; tabs.selectedSegment = value ? 1 : 0; timeline.imageMode = value
        NSLayoutConstraint.deactivate(detailConstraints)
        details.subviews.forEach { $0.removeFromSuperview() }
        let child = value ? images.view : lyrics.view
        child.translatesAutoresizingMaskIntoConstraints = false; details.addSubview(child)
        detailConstraints = [child.leadingAnchor.constraint(equalTo: details.leadingAnchor), child.trailingAnchor.constraint(equalTo: details.trailingAnchor), child.topAnchor.constraint(equalTo: details.topAnchor), child.bottomAnchor.constraint(equalTo: details.bottomAnchor)]
        NSLayoutConstraint.activate(detailConstraints)
    }
    @objc private func changePlacementMode() {
        let value = tabs.selectedSegment == 1
        timeline.cancelDrag()
        guard (imageMode ? images.finishEditing() : lyrics.finishEditing()) else {
            tabs.selectedSegment = imageMode ? 1 : 0; onError?("入力を確定し、開始・終了を正しい区間にしてください。"); return
        }
        showMode(value); onModeChange?(value)
    }
    private func updateDisplayRange() {
        timeline.cancelDrag()
        let span = showsWholeSong && duration.isFinite && duration > 0 ? duration : visibleSpan
        timeline.visibleSpan = span
        zoom.doubleValue = visibleSpan
        zoom.isEnabled = available && !showsWholeSong
        wholeSong.state = showsWholeSong ? .on : .off
        zoomLabel.stringValue = String(format: "%.1f秒", span)
    }
    @objc private func changeWholeSong() {
        showsWholeSong = wholeSong.state == .on
        onWholeSongChange?(showsWholeSong)
    }
    @objc private func changeZoom() { visibleSpan = zoom.doubleValue; onVisibleSpanChange?(visibleSpan) }
    func setAvailable(_ value: Bool) { lyrics.setAvailable(value); images.setAvailable(value); tabs.isEnabled = value; available = value; wholeSong.isEnabled = value; zoom.isEnabled = value && !showsWholeSong }
    func cancelTimelineEdit() { timeline.cancelDrag() }
    func finishEditing() -> Bool { imageMode ? images.finishEditing() : lyrics.finishEditing() }
}
