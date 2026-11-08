import AppKit

@MainActor
final class LyricsEditor: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: ((LyricsTrack) -> Void)?
    var onSeek: ((Double) -> Void)?
    var currentTime = 0.0
    var duration = 0.0
    private(set) var track = LyricsTrack()
    private let table = NSTableView()
    private let body = NSTextView()
    private let start = NSTextField(string: "0")
    private let end = NSTextField(string: "2")
    private let width = NSSlider(value: 3, minValue: 0, maxValue: 12, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "3.0 px")
    private let color = NSColorWell()
    private let message = NSTextField(labelWithString: "音声を読み込んで歌詞を追加してください")
    private var editControls: [NSControl] = []
    private var available = false

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
        body.font = .systemFont(ofSize: 14); body.isRichText = false
        body.isAutomaticQuoteSubstitutionEnabled = false
        let textScroll = NSScrollView(); textScroll.documentView = body; textScroll.hasVerticalScroller = true
        body.isVerticallyResizable = true; body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]; body.textContainer?.widthTracksTextView = true
        start.widthAnchor.constraint(equalToConstant: 65).isActive = true
        end.widthAnchor.constraint(equalToConstant: 65).isActive = true
        let apply = NSButton(title: "歌詞を適用", target: self, action: #selector(applyClip))
        let timing = NSStackView(views: [NSTextField(labelWithString: "開始"), start, NSTextField(labelWithString: "終了"), end, apply])
        timing.spacing = 8
        let detail = NSStackView(views: [textScroll, timing]); detail.orientation = .vertical; detail.spacing = 6
        textScroll.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        let content = NSStackView(views: [list, detail]); content.spacing = 12; content.distribution = .fill
        content.heightAnchor.constraint(equalToConstant: 105).isActive = true
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        for child in [style, content, message] { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        editControls = [add, remove, apply, start, end, color, width]
        setAvailable(false)
    }

    func load(_ value: LyricsTrack) {
        track = value
        width.doubleValue = value.outlineWidth; color.color = value.outlineColor.nsColor
        updateWidthLabel(); table.reloadData(); table.deselectAll(nil)
        body.string = ""; start.stringValue = "0"; end.stringValue = "2"
    }
    func setAvailable(_ value: Bool) {
        available = value
        editControls.forEach { $0.isEnabled = value }
        body.isEditable = value; table.isEnabled = value
    }
    func numberOfRows(in tableView: NSTableView) -> Int { track.clips.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = track.clips[row]
        let label = NSTextField(labelWithString: String(format: "%.2f–%.2f  ", clip.start, clip.end) + clip.text.replacingOccurrences(of: "\n", with: " / "))
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard track.clips.indices.contains(table.selectedRow) else { return }
        let clip = track.clips[table.selectedRow]
        body.string = clip.text; start.stringValue = String(format: "%.3f", clip.start); end.stringValue = String(format: "%.3f", clip.end)
        onSeek?(clip.start)
    }
    private func commit(_ value: LyricsTrack, selectedID: UUID?) {
        do {
            try value.validate(duration: duration)
            track = value; table.reloadData()
            if let id = selectedID, let index = track.clips.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            message.stringValue = "歌詞を反映しました。文字・時刻の編集後は「歌詞を適用」を押してください。"
            onChange?(track)
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func addClip() {
        guard available else { return }
        if let index = track.clips.firstIndex(where: { $0.start <= currentTime && currentTime < $0.end }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); return
        }
        let limit = track.clips.first(where: { $0.start > currentTime })?.start ?? duration
        guard limit - currentTime >= 1.0 / 30 else { message.stringValue = "歌詞を置く空き時間がありません。"; return }
        let clip = LyricClip(start: currentTime, end: min(currentTime + 2, limit), text: "歌詞を入力")
        var value = track; value.clips.append(clip); value.clips.sort { $0.start < $1.start }
        commit(value, selectedID: clip.id)
    }
    @objc private func removeClip() {
        guard available, track.clips.indices.contains(table.selectedRow) else { return }
        var value = track; value.clips.remove(at: table.selectedRow)
        commit(value, selectedID: nil); body.string = ""
    }
    @objc private func applyClip() {
        guard available, track.clips.indices.contains(table.selectedRow) else { return }
        guard let begin = Double(start.stringValue), let finish = Double(end.stringValue) else { message.stringValue = "開始・終了を秒数で入力してください。"; return }
        var value = track
        let id = value.clips[table.selectedRow].id
        value.clips[table.selectedRow] = LyricClip(id: id, start: begin, end: finish, text: body.string)
        value.clips.sort { $0.start < $1.start }; commit(value, selectedID: id)
    }
    private func updateWidthLabel() { widthLabel.stringValue = String(format: "%.1f px", track.outlineWidth) }
    @objc private func changeStyle() {
        guard available else { return }
        track.outlineWidth = (width.doubleValue * 10).rounded() / 10
        track.outlineColor = LyricsColor(color.color)
        updateWidthLabel(); onChange?(track)
    }
}
