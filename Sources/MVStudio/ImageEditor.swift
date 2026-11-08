import AppKit
import UniformTypeIdentifiers

@MainActor
final class ImageEditor: NSViewController, NSTextFieldDelegate {
    var onProcessing: ((Bool) -> Void)?
    var onAssetsReload: (() -> Void)?
    var onBeginTextEditing: (() -> Void)?
    var onEndTextEditing: (() -> Void)?
    var onChange: ((ImageTrack) -> Void)?
    var onPreview: ((ImageTrack) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onBeginEdit: (() -> Void)?
    var currentTime = 0.0
    var duration = 0.0
    var snapGrid = TimelineSnapGrid()
    var timeline: TimelineView? { didSet { connectTimeline() } }
    private(set) var track = ImageTrack()
    private(set) var projectURL: URL?
    private(set) var thumbnails: [UUID: NSImage] = [:]
    private(set) var missing = Set<UUID>()
    let store = ImageAssetStore()
    private var generation = UUID()
    private var assetRefreshRevision = 0
    private var available = false
    private var processing = false
    var isProcessing: Bool { processing }
    private var refreshing = false
    private var timingIsValid = true
    private var selectedID: UUID?
    private var selectedSlot = 1
    private let name = NSTextField(labelWithString: "画像行を選択し、画像を配置してください")
    private let start = NSTextField(string: "0")
    private let end = NSTextField(string: "2")
    private let slot = NSPopUpButton()
    private let pulse = NSButton(checkboxWithTitle: "拍に合わせた拡大", target: nil, action: nil)
    private let amount = NSSlider(value: 8, minValue: 0, maxValue: 25, target: nil, action: nil)
    private let amountLabel = NSTextField(labelWithString: "8%")
    private let message = NSTextField(labelWithString: "画像を空白へドロップするか、ボタンで配置できます")
    private var controls: [NSControl] = []
    private var clipControls: [NSControl] = []
    private var manager: ImageAssetManager?
    private var importTask: Task<Void, Never>?

    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 12; view = root
        let add = NSButton(title: "＋画像を配置…", target: self, action: #selector(addImage))
        let remove = NSButton(title: "配置を削除", target: self, action: #selector(removeClip))
        let manage = NSButton(title: "画像管理…", target: self, action: #selector(openManager))
        let replace = NSButton(title: "画像を変更…", target: self, action: #selector(changeImage))
        start.delegate = self; end.delegate = self
        start.identifier = NSUserInterfaceItemIdentifier("images.start"); end.identifier = NSUserInterfaceItemIdentifier("images.end")
        for field in [start, end] { field.widthAnchor.constraint(equalToConstant: 100).isActive = true }
        slot.addItems(withTitles: ["画像1（最背面）", "画像2", "画像3（最前面）"])
        slot.target = self; slot.action = #selector(changePlacement)
        pulse.target = self; pulse.action = #selector(changePlacement)
        amount.target = self; amount.action = #selector(changePlacement); amount.isContinuous = true
        amount.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let toolbar = row([add, remove, manage])
        let selection = row([name, replace])
        let timing = row([NSTextField(labelWithString: "開始"), start, NSTextField(labelWithString: "終了"), end, NSTextField(labelWithString: "秒　移動先"), slot])
        let effect = row([pulse, NSTextField(labelWithString: "強さ"), amount, amountLabel])
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor; message.lineBreakMode = .byTruncatingTail
        name.lineBreakMode = .byTruncatingMiddle
        for child in [toolbar, selection, timing, effect, message] { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        controls = [add, remove, manage, replace, start, end, slot, pulse, amount]
        clipControls = [remove, replace, start, end, slot, pulse, amount]
        refreshControls()
    }
    private func row(_ views: [NSView]) -> NSStackView { let row = NSStackView(views: views); row.spacing = 10; return row }
    private func connectTimeline() {
        timeline?.onImageSelect = { [weak self] id, slot in self?.select(id, slot: slot) }
        timeline?.onImagePreview = { [weak self] value in self?.onPreview?(value) }
        timeline?.onImageCommit = { [weak self] value, id in self?.commit(value, selectedID: id) }
        timeline?.onDropImage = { [weak self] url, slot, time in self?.importFile(url, placement: (slot, time)) }
        timeline?.images = track
    }
    func load(_ value: ImageTrack, projectURL: URL?) {
        generation = UUID(); importTask?.cancel(); processing = false; onProcessing?(false)
        track = value; self.projectURL = projectURL; selectedID = nil; selectedSlot = 1
        thumbnails = [:]; missing = []; timeline?.images = value; timeline?.selectedImageID = nil; timeline?.selectedSlot = 1
        refreshSelection(); refreshAssets()
    }
    var managerWindow: NSWindow? { manager?.window }
    func restore(_ value: ImageTrack) {
        let selection = selectedID ?? value.clips.first(where: { candidate in track.clip(candidate.id) == nil })?.id, slot = selectedSlot
        load(value, projectURL: projectURL)
        selectedID = value.clip(selection)?.id; selectedSlot = selectedID.flatMap { value.slot(of: $0) } ?? slot
        refreshSelection(); manager?.reload()
    }
    func setAvailable(_ value: Bool) { available = value; refreshControls() }
    private func refreshControls() {
        controls.forEach { $0.isEnabled = available && !processing && manager == nil }
        clipControls.forEach { $0.isEnabled = available && !processing && manager == nil && track.clip(selectedID) != nil }
        timeline?.isEnabled = available && !processing && manager == nil
    }
    private func select(_ id: UUID?, slot: Int) {
        selectedID = id; selectedSlot = slot; refreshSelection()
    }
    private func refreshSelection() {
        timingIsValid = true
        refreshing = true; defer { refreshing = false }
        timeline?.selectedImageID = selectedID; timeline?.selectedSlot = selectedSlot
        if let clip = track.clip(selectedID) {
            name.stringValue = "画像\(track.slot(of: clip.id) ?? selectedSlot) / \(track.asset(clip.assetID)?.name ?? "不明")"
            start.stringValue = String(clip.start); end.stringValue = String(clip.end)
            slot.selectItem(at: (track.slot(of: clip.id) ?? 1) - 1)
            pulse.state = clip.beatPulseEnabled ? .on : .off; amount.doubleValue = clip.pulseAmount * 100
        } else { name.stringValue = "画像\(selectedSlot)：空白へ画像を配置してください" }
        amountLabel.stringValue = String(format: "%.1f%%", amount.doubleValue)
        refreshControls()
    }
    func commit(_ value: ImageTrack, selectedID: UUID? = nil, refreshEditor: Bool = true) {
        do {
            try value.validate(duration: duration)
            guard value != track else { message.stringValue = "変更は自動保存されます。"; return }
            track = value; self.selectedID = selectedID
            if let selectedID { selectedSlot = value.slot(of: selectedID) ?? selectedSlot }
            timeline?.images = value; timeline?.selectedImageID = selectedID
            if refreshEditor { refreshSelection() }
            message.stringValue = "変更は自動保存されます。"
            onChange?(value); refreshAssets()
        } catch { report(error) }
    }
    func report(_ error: Error) { message.stringValue = error.localizedDescription; manager?.showError(error) }
    func finishEditing() -> Bool {
        guard !processing else { return false }
        if let editor = view.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        changePlacement()
        guard timingIsValid else { return false }
        return view.window?.makeFirstResponder(nil) ?? true
    }
    func controlTextDidBeginEditing(_ obj: Notification) { onBeginTextEditing?() }
    func controlTextDidChange(_ obj: Notification) {
        if let editor = (obj.object as? NSTextField)?.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        changePlacement()
    }
    func controlTextDidEndEditing(_ obj: Notification) { changePlacement(); refreshSelection(); onEndTextEditing?() }
    @objc private func changePlacement() {
        guard available, !refreshing, !processing, var clip = track.clip(selectedID) else { return }
        guard let begin = Double(start.stringValue), let finish = Double(end.stringValue), begin.isFinite, finish.isFinite, begin >= 0, finish <= duration else { timingIsValid = false; message.stringValue = "開始・終了を秒数で入力してください。"; return }
        clip.start = begin == clip.start ? begin : max(0, snapGrid.nearest(begin)); clip.end = finish == clip.end ? finish : max(0, snapGrid.nearest(finish))
        clip.beatPulseEnabled = pulse.state == .on; clip.pulseAmount = amount.doubleValue / 100
        do {
            let value = try track.updating(clip, slot: slot.indexOfSelectedItem + 1, duration: duration)
            timingIsValid = true
            commit(value, selectedID: clip.id, refreshEditor: false)
            amountLabel.stringValue = String(format: "%.1f%%", amount.doubleValue)
        } catch { timingIsValid = false; report(error) }
    }
    @objc private func removeClip() {
        guard available, let id = selectedID else { return }
        onBeginEdit?(); commit(track.removingClip(id: id))
    }
    @objc private func addImage() {
        guard available, finishEditing() else { return }
        onBeginEdit?()
        chooseImage { [weak self] url in
            guard let self else { return }
            self.importFile(url, placement: (self.selectedSlot, self.currentTime))
        }
    }
    @objc private func changeImage() {
        guard available, let id = selectedID, finishEditing() else { return }
        onBeginEdit?()
        chooseImage { [weak self] url in self?.importFile(url, replacingClip: id) }
    }
    private func chooseImage(_ completion: (URL) -> Void) {
        guard let projectURL else { return }
        if !track.assets.isEmpty {
            let alert = NSAlert(); alert.messageText = "使用する画像"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
            popup.addItems(withTitles: track.assets.map { $0.name + (missing.contains($0.id) ? "（見つかりません）" : "") })
            alert.accessoryView = popup; alert.addButton(withTitle: "選択した画像を使用"); alert.addButton(withTitle: "ファイルから読み込む…"); alert.addButton(withTitle: "キャンセル")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { completion(track.assets[popup.indexOfSelectedItem].reference.resolve(projectURL: projectURL)); return }
            if response != .alertSecondButtonReturn { return }
        }
        if let url = Self.chooseFile() { completion(url) }
    }
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    func importFile(_ url: URL, placement: (slot: Int, time: Double)? = nil, replacingAsset: UUID? = nil, replacingClip: UUID? = nil) {
        guard available, !processing, let projectURL else { return }
        let token = generation
        onBeginEdit?(); processing = true; onProcessing?(true); refreshControls(); manager?.setProcessing(true)
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { processing = false; onProcessing?(false); refreshControls(); manager?.setProcessing(false) } }
            do {
                _ = try await store.image(at: url)
                try Task.checkCancellation()
                guard generation == token else { return }
                var value = track
                var selection = selectedID
                if let id = replacingAsset { value = try value.replacingAsset(id: id, url: url, projectURL: projectURL) }
                else {
                    let assetID = value.register(url: url, projectURL: projectURL)
                    if let placement {
                        let result = try value.adding(assetID: assetID, at: placement.time, slot: placement.slot, duration: duration, grid: snapGrid)
                        value = result.track; selection = result.clip.id
                    } else if let replacingClip, var clip = value.clip(replacingClip) {
                        clip.assetID = assetID; value = try value.updating(clip, slot: value.slot(of: replacingClip)!, duration: duration)
                    } else if replacingClip != nil { throw StudioError.message("置き換える配置が見つかりません。") }
                }
                await store.invalidate()
                guard generation == token else { return }
                commit(value, selectedID: selection)
                onAssetsReload?(); refreshAssets()
                if let placement, let clip = value.clip(selection) { selectedSlot = placement.slot; onSeek?(clip.start) }
            } catch is CancellationError { }
            catch { if generation == token { report(error) } }
        }
    }
    func refreshAssets() {
        guard let projectURL else { return }
        let assetIDs = Set(track.assets.map(\.id))
        thumbnails = thumbnails.filter { assetIDs.contains($0.key) }; missing.formIntersection(assetIDs)
        assetRefreshRevision += 1
        let revision = assetRefreshRevision
        let token = generation, assets = track.assets
        Task { [weak self] in
            guard let self else { return }
            for asset in assets {
                let image = try? await store.image(at: asset.reference.resolve(projectURL: projectURL), maximumSize: 160)
                guard generation == token, revision == assetRefreshRevision, track.asset(asset.id)?.reference == asset.reference else { continue }
                if let image { thumbnails[asset.id] = NSImage(cgImage: image, size: .zero); missing.remove(asset.id) }
                else { thumbnails[asset.id] = nil; missing.insert(asset.id) }
            }
            guard generation == token, revision == assetRefreshRevision else { return }
            timeline?.missingAssets = missing; manager?.reload()
        }
    }
    @objc func openManager() {
        guard available, !processing, manager == nil, finishEditing(), let window = view.window else { return }
        timeline?.cancelDrag(); onBeginEdit?()
        let controller = ImageAssetManager(editor: self)
        manager = controller; refreshControls()
        window.beginSheet(controller.window!) { [weak self] _ in self?.manager = nil; self?.refreshControls() }
    }
    func deleteAsset(_ id: UUID, includingPlacements: Bool) {
        do { commit(try track.removingAsset(id: id, includingPlacements: includingPlacements), selectedID: selectedID); manager?.reload() }
        catch { report(error) }
    }
    func usageDescription(_ id: UUID) -> String {
        track.uses(id).map { "画像\(track.slot(of: $0.id) ?? 1)　\(TimelineGeometry.label($0.start))–\(TimelineGeometry.label($0.end))" }.joined(separator: "\n")
    }
}
