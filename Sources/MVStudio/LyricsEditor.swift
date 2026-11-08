import AppKit

@MainActor
final class LyricsEditor: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    var onBeginTextEditing: (() -> Void)?
    var onEndTextEditing: (() -> Void)?
    var onChange: ((LyricsTrack) -> Void)?
    var onPreview: ((LyricsTrack) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onCapturePlaybackTime: (() -> Double)?
    var snapGrid = TimelineSnapGrid() { didSet { timeline.snapGrid = snapGrid } }
    var currentTime = 0.0 { didSet { timeline.currentTime = currentTime } }
    var duration = 0.0 { didSet { timeline.duration = duration } }
    private(set) var track = LyricsTrack()
    let timeline = TimelineView()
    private let table = NSTableView()
    private let body = NSTextView()
    private let start = NSTextField(string: "0")
    private let end = NSTextField(string: "2")
    private let width = NSSlider(value: 3, minValue: 0, maxValue: 12, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "3.0 px")
    private let color = NSColorWell()
    private let chain = NSButton(checkboxWithTitle: "直前のテロップ末尾に連結", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "音声を読み込んで歌詞を追加してください")
    private var editControls: [NSControl] = []
    private var available = false
    private var refreshingSelection = false
    private var timingIsValid = true

    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8
        view = root
        let title = NSTextField(labelWithString: "歌詞テロップ")
        title.font = .boldSystemFont(ofSize: 14)
        let add = NSButton(title: "＋歌詞", target: self, action: #selector(addClip))
        let remove = NSButton(title: "削除", target: self, action: #selector(removeClip))
        color.color = .black; color.target = self; color.action = #selector(changeStyle)
        color.widthAnchor.constraint(equalToConstant: 48).isActive = true
        width.target = self; width.action = #selector(changeStyle); width.isContinuous = true
        width.widthAnchor.constraint(equalToConstant: 120).isActive = true
        widthLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let style = NSStackView(views: [title, add, remove, NSTextField(labelWithString: "縁取り色"), color, NSTextField(labelWithString: "太さ（0で無効）"), width, widthLabel])
        style.spacing = 10
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("lyrics")); column.title = "歌詞（開始〜終了 秒）"; column.width = 350
        table.addTableColumn(column); table.delegate = self; table.dataSource = self
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        list.widthAnchor.constraint(equalToConstant: 350).isActive = true
        body.identifier = NSUserInterfaceItemIdentifier("lyrics.body")
        start.identifier = NSUserInterfaceItemIdentifier("lyrics.start")
        end.identifier = NSUserInterfaceItemIdentifier("lyrics.end")
        body.delegate = self
        start.delegate = self; end.delegate = self
        body.font = .systemFont(ofSize: 14); body.isRichText = false
        body.isAutomaticQuoteSubstitutionEnabled = false
        let textScroll = NSScrollView(); textScroll.documentView = body; textScroll.hasVerticalScroller = true
        body.isVerticallyResizable = true; body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]; body.textContainer?.widthTracksTextView = true
        start.widthAnchor.constraint(equalToConstant: 65).isActive = true
        end.widthAnchor.constraint(equalToConstant: 65).isActive = true
        chain.target = self; chain.action = #selector(changeChain)
        chain.identifier = NSUserInterfaceItemIdentifier("lyrics.chain")
        let timing = NSStackView(views: [NSTextField(labelWithString: "開始"), start, NSTextField(labelWithString: "終了"), end])
        timing.spacing = 8
        let detail = NSStackView(views: [textScroll, timing, chain]); detail.orientation = .vertical; detail.spacing = 6
        textScroll.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        let content = NSStackView(views: [list, detail]); content.spacing = 12; content.distribution = .fill
        content.heightAnchor.constraint(equalToConstant: 135).isActive = true
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        timeline.onBeginEdit = { [weak self] in _ = self?.onCapturePlaybackTime?() }
        timeline.onSeek = { [weak self] time in self?.onSeek?(time) }
        timeline.onSelect = { [weak self] id in self?.selectFromTimeline(id) }
        timeline.onPreview = { [weak self] value in self?.onPreview?(value) }
        timeline.onCommit = { [weak self] value, id in self?.commit(value, selectedID: id) }
        timeline.onError = { [weak self] error in self?.message.stringValue = error.localizedDescription }
        for child in [style, content, message] { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        editControls = [add, remove, start, end, color, width, chain]
        setAvailable(false)
    }

    func load(_ value: LyricsTrack) {
        timeline.cancelDrag()
        track = value; timingIsValid = true
        timeline.track = value; timeline.selectedID = nil
        width.doubleValue = value.outlineWidth; color.color = value.outlineColor.nsColor
        updateWidthLabel(); table.reloadData(); table.deselectAll(nil)
        body.string = ""; start.stringValue = "0"; end.stringValue = "2"; chain.state = .off
    }
    func restore(_ value: LyricsTrack) {
        let selection = timeline.selectedID ?? value.clips.first(where: { candidate in !track.clips.contains(where: { $0.id == candidate.id }) })?.id
        load(value)
        if let selection { selectFromTimeline(selection) }
    }
    func setAvailable(_ value: Bool) {
        available = value
        timeline.isEnabled = value
        editControls.forEach { $0.isEnabled = value }
        body.isEditable = value; table.isEnabled = value
    }
    func numberOfRows(in tableView: NSTableView) -> Int { track.clips.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = track.clips[row]
        let label = NSTextField(labelWithString: (clip.predecessorID == nil ? "" : "↳ ") + String(format: "%.2f–%.2f  ", clip.start, clip.end) + clip.text.replacingOccurrences(of: "\n", with: " / "))
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshingSelection else { return }
        displaySelection()
        guard track.clips.indices.contains(table.selectedRow) else { return }
        onSeek?(track.clips[table.selectedRow].start)
    }
    private func displaySelection() {
        timingIsValid = true
        timeline.selectedID = track.clips.indices.contains(table.selectedRow) ? track.clips[table.selectedRow].id : nil
        guard track.clips.indices.contains(table.selectedRow) else { return }
        let clip = track.clips[table.selectedRow]
        body.string = clip.text; start.stringValue = String(clip.start); end.stringValue = String(clip.end)
        chain.state = clip.predecessorID == nil ? .off : .on
    }
    private func commit(_ value: LyricsTrack, selectedID: UUID?, refreshEditor: Bool = true) {
        do {
            try value.validate(duration: duration)
            message.stringValue = "変更は自動で反映・保存されます。"
            guard value != track else { return }
            refreshingSelection = true
            defer { refreshingSelection = false }
            track = value; timeline.track = value; timeline.selectedID = selectedID; table.reloadData()
            if let id = selectedID, let index = track.clips.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            else { table.deselectAll(nil) }
            if refreshEditor { displaySelection() }
            onChange?(track)
        } catch { message.stringValue = error.localizedDescription }
    }
    private func selectFromTimeline(_ id: UUID) {
        guard let index = track.clips.firstIndex(where: { $0.id == id }) else { return }
        refreshingSelection = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        displaySelection()
        refreshingSelection = false
    }
    func finishEditing() -> Bool {
        if body.hasMarkedText() { return false }
        applyEditorChanges()
        guard timingIsValid else { return false }
        return view.window?.makeFirstResponder(nil) ?? true
    }
    func cancelTimelineEdit() { timeline.cancelDrag() }
    @objc private func addClip() {
        guard available else { return }
        do {
            let time = onCapturePlaybackTime?() ?? currentTime
            let result = try track.adding(at: time, duration: duration, grid: snapGrid)
            commit(result.track, selectedID: result.clip.id)
            onSeek?(result.clip.start)
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func removeClip() {
        guard available, track.clips.indices.contains(table.selectedRow) else { return }
        do {
            let value = try track.removing(id: track.clips[table.selectedRow].id, duration: duration)
            commit(value, selectedID: nil); body.string = ""; chain.state = .off
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func changeChain() {
        guard available, track.clips.indices.contains(table.selectedRow) else { return }
        let clip = track.clips[table.selectedRow]
        do {
            let value = try track.settingChain(id: clip.id, enabled: chain.state == .on, duration: duration)
            commit(value, selectedID: clip.id)
        } catch {
            chain.state = clip.predecessorID == nil ? .off : .on
            message.stringValue = error.localizedDescription
        }
    }
    func textDidBeginEditing(_ notification: Notification) { onBeginTextEditing?() }
    func textDidChange(_ notification: Notification) {
        guard !body.hasMarkedText() else { return }
        applyEditorChanges()
    }
    func textDidEndEditing(_ notification: Notification) { applyEditorChanges(); onEndTextEditing?() }
    func controlTextDidBeginEditing(_ obj: Notification) { onBeginTextEditing?() }
    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField,
           let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        applyEditorChanges()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        defer { onEndTextEditing?() }
        applyEditorChanges()
        if let clip = track.clips.first(where: { $0.id == timeline.selectedID }) {
            start.stringValue = String(clip.start); end.stringValue = String(clip.end)
        }
    }
    private func applyEditorChanges() {
        guard available, !refreshingSelection, !body.hasMarkedText(), track.clips.indices.contains(table.selectedRow) else { return }
        guard let begin = Double(start.stringValue), let finish = Double(end.stringValue) else { timingIsValid = false; message.stringValue = "開始・終了を秒数で入力してください。"; return }
        let clip = track.clips[table.selectedRow]
        do {
            let snappedStart = begin == clip.start ? begin : max(0, snapGrid.nearest(begin))
            let snappedEnd = finish == clip.end ? finish : max(0, snapGrid.nearest(finish))
            let value = try track.updating(id: clip.id, start: snappedStart, end: snappedEnd, text: body.string, duration: duration)
            timingIsValid = true
            commit(value, selectedID: clip.id, refreshEditor: false)
            chain.state = track.clips.first(where: { $0.id == clip.id })?.predecessorID == nil ? .off : .on
            if begin != clip.start, finish == clip.end, let updated = track.clips.first(where: { $0.id == clip.id }) {
                self.end.stringValue = String(updated.end)
            }
        } catch { timingIsValid = false; message.stringValue = error.localizedDescription }
    }
    private func updateWidthLabel() { widthLabel.stringValue = String(format: "%.1f px", track.outlineWidth) }
    @objc private func changeStyle() {
        guard available else { return }
        track.outlineWidth = (width.doubleValue * 10).rounded() / 10
        track.outlineColor = LyricsColor(color.color)
        updateWidthLabel(); timeline.track = track; onChange?(track)
    }
}
