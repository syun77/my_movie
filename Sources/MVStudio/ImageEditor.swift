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
    private let start = DragValueField(frame: .zero)
    private let end = DragValueField(frame: .zero)
    private let slot = NSPopUpButton()
    private let automatic = NSPopUpButton()
    private let keySnap = NSButton(checkboxWithTitle: "拍スナップ", target: nil, action: nil)
    private let graphParameter = NSPopUpButton()
    private let minimum = DragValueField(frame: .zero)
    private let maximum = DragValueField(frame: .zero)
    private var valueFields: [ImageParameter: DragValueField] = [:]
    private var valueDrag: ValueDrag?

    private enum ValueTarget: Equatable {
        case base(ImageParameter)
        case minimum(ImageParameter)
        case maximum(ImageParameter)

        var parameter: ImageParameter {
            switch self {
            case let .base(parameter), let .minimum(parameter), let .maximum(parameter): return parameter
            }
        }

        var initialValue: Double {
            switch self {
            case .base: return parameter.defaultValue
            case .minimum: return parameter.defaultRange.lowerBound
            case .maximum: return parameter.defaultRange.upperBound
            }
        }

        func value(in clip: ImageClip) -> Double? {
            switch self {
            case .base: return clip.baseValue(parameter)
            case .minimum: return clip.curve(parameter)?.minimum
            case .maximum: return clip.curve(parameter)?.maximum
            }
        }

        func apply(_ value: Double, to clip: inout ImageClip, resetting: Bool = false) {
            switch self {
            case .base:
                clip.setBaseValue(value, for: parameter, resetting: resetting)
            case .minimum, .maximum:
                guard var curve = clip.curve(parameter) else { return }
                if case .minimum = self {
                    curve.minimum = value
                    if resetting, curve.maximum <= value { curve.maximum = parameter.defaultRange.upperBound }
                } else {
                    curve.maximum = value
                    if resetting, curve.minimum >= value { curve.minimum = parameter.defaultRange.lowerBound }
                }
                clip.setCurve(curve)
            }
        }
    }

    private struct ValueDrag {
        let target: ValueTarget
        let field: DragValueField
        let original: ImageClip
        let initial: Double
        var preview: ImageTrack?
    }
    private var drafts: [ImageParameter: String] = [:]
    private var graphParameters: [ImageParameter] = []
    private var rangeParameter: ImageParameter?
    private let amount = NSSlider(value: 8, minValue: 0, maxValue: 25, target: nil, action: nil)
    private let amountLabel = NSTextField(labelWithString: "8%")
    private let message = NSTextField(labelWithString: "画像を空白へドロップするか、ボタンで配置できます")
    private var controls: [NSControl] = []
    private var clipControls: [NSControl] = []
    private var manager: ImageAssetManager?
    private var importTask: Task<Void, Never>?

    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 6; view = root
        let add = NSButton(title: "＋画像を配置…", target: self, action: #selector(addImage))
        let remove = NSButton(title: "配置を削除", target: self, action: #selector(removeClip))
        let manage = NSButton(title: "画像管理…", target: self, action: #selector(openManager))
        let replace = NSButton(title: "画像を変更…", target: self, action: #selector(changeImage))
        start.delegate = self; end.delegate = self
        start.stringValue = "0"; end.stringValue = "2"
        bindTimingFields()
        start.identifier = NSUserInterfaceItemIdentifier("images.start"); end.identifier = NSUserInterfaceItemIdentifier("images.end")
        for field in [start, end] { field.widthAnchor.constraint(equalToConstant: 76).isActive = true }
        slot.addItems(withTitles: ["画像1（最背面）", "画像2", "画像3（最前面）"])
        slot.target = self; slot.action = #selector(changePlacement)
        automatic.addItems(withTitles: AutomaticAnimation.allCases.map(\.title))
        automatic.identifier = NSUserInterfaceItemIdentifier("images.automatic")
        automatic.target = self; automatic.action = #selector(changeAutomatic)
        amount.target = self; amount.action = #selector(changeAutomatic); amount.isContinuous = true
        amount.widthAnchor.constraint(equalToConstant: 88).isActive = true
        keySnap.state = .on
        keySnap.identifier = NSUserInterfaceItemIdentifier("images.keySnap")
        keySnap.target = self; keySnap.action = #selector(changeKeySnap)
        keySnap.toolTip = "制御点を16分音符またはクリップの端に揃えます"
        graphParameter.target = self; graphParameter.action = #selector(changeGraphParameter)
        for (field, id) in [(minimum, "minimum"), (maximum, "maximum")] {
            field.identifier = NSUserInterfaceItemIdentifier("images.graph." + id)
            field.delegate = self; field.target = self; field.action = #selector(changeGraphRange)
            field.toolTip = "ダブルクリックで入力、左右ドラッグで調整、ホイールクリックで初期値"
            connectValueField(field) { [weak self, weak field] in
                guard let self, let parameter = self.rangeParameter else { return nil }
                return field === self.minimum ? .minimum(parameter) : .maximum(parameter)
            }
            field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        }
        let toolbar = row([add, remove, manage])
        let selection = row([name, replace])
        let timing = row([NSTextField(labelWithString: "開始"), start, NSTextField(labelWithString: "終了"), end, NSTextField(labelWithString: "レイヤー"), slot])
        let effect = row([NSTextField(labelWithString: "自動アニメ"), automatic, amount, amountLabel, keySnap])
        let horizontal = row([parameterControls(.x), parameterControls(.y)])
        let vertical = row([parameterControls(.scale), parameterControls(.rotation)])
        let graphs = row([NSTextField(labelWithString: "グラフ"), graphParameter, NSTextField(labelWithString: "最小"), minimum,
                          NSTextField(labelWithString: "最大"), maximum])
        graphParameter.widthAnchor.constraint(equalToConstant: 94).isActive = true
        graphs.toolTip = "グラフの表示範囲を指定し、Returnで確定します"
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor; message.lineBreakMode = .byTruncatingTail
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for child in [toolbar, selection, timing, effect, horizontal, vertical, graphs, message] { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        clipControls += [remove, replace, start, end, slot, automatic, amount, graphParameter, minimum, maximum]
        controls = [add, manage, keySnap] + clipControls
        refreshControls()
    }
    private func row(_ views: [NSView]) -> NSStackView { let row = NSStackView(views: views); row.spacing = 10; return row }
    private func connectTimeline() {
        timeline?.onImageSelect = { [weak self] id, slot in self?.select(id, slot: slot) }
        timeline?.onImagePreview = { [weak self] value in self?.onPreview?(value) }
        timeline?.onImageCommit = { [weak self] value, id in self?.commit(value, selectedID: id) }
        timeline?.onGraphSelection = { [weak self] in self?.refreshGraphControls() }
        timeline?.onGraphRangeEdit = { [weak self] editingMaximum in
            guard let self else { return }
            let field = editingMaximum ? self.maximum : self.minimum
            if field.isEnabled { field.selectText(nil) }
        }
        timeline?.keySnapEnabled = keySnap.state == .on
        timeline?.onDropImage = { [weak self] url, slot, time in self?.importFile(url, placement: (slot, time)) }
        timeline?.images = track
    }
    func load(_ value: ImageTrack, projectURL: URL?) {
        timeline?.resetGraphDisclosure()
        replaceTrack(value, projectURL: projectURL)
    }
    private func replaceTrack(_ value: ImageTrack, projectURL: URL?) {
        cancelValueDrag()
        generation = UUID(); importTask?.cancel(); processing = false; onProcessing?(false)
        drafts.removeAll()
        track = value; self.projectURL = projectURL; selectedID = nil; selectedSlot = 1
        thumbnails = [:]; missing = []; timeline?.images = value; timeline?.selectedImageID = nil; timeline?.selectedSlot = 1
        refreshSelection(); refreshAssets()
    }
    var managerWindow: NSWindow? { manager?.window }
    func restore(_ value: ImageTrack) {
        let selection = selectedID ?? value.clips.first(where: { candidate in track.clip(candidate.id) == nil })?.id, slot = selectedSlot
        let parameter = timeline?.selectedParameter
        let key = timeline?.selectedKeyID
        replaceTrack(value, projectURL: projectURL)
        selectedID = value.clip(selection)?.id; selectedSlot = selectedID.flatMap { value.slot(of: $0) } ?? slot
        refreshSelection(); manager?.reload()
        if let parameter, let curve = value.clip(selectedID)?.curve(parameter) {
            timeline?.selectGraph(parameter, key: curve.keys.first { $0.id == key }?.id, reveal: true)
        }
    }
    func setAvailable(_ value: Bool) {
        if !value { cancelValueDrag() }
        available = value
        refreshControls()
    }
    private func refreshControls() {
        controls.forEach { $0.isEnabled = available && !processing && manager == nil }
        clipControls.forEach { $0.isEnabled = available && !processing && manager == nil && track.clip(selectedID) != nil }
        timeline?.isEnabled = available && !processing && manager == nil
        refreshGraphControls()
        amount.isEnabled = automatic.isEnabled && track.clip(selectedID)?.automaticAnimation != AutomaticAnimation.off
    }
    private func select(_ id: UUID?, slot: Int) {
        cancelValueDrag()
        drafts.removeAll()
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
            automatic.selectItem(withTitle: clip.automaticAnimation.title); amount.doubleValue = clip.pulseAmount * 100
        } else { name.stringValue = "画像\(selectedSlot)：空白へ画像を配置してください" }
        amountLabel.stringValue = String(format: "%.1f%%", amount.doubleValue)
        refreshAnimationValues()
        refreshControls()
    }
    func commit(_ value: ImageTrack, selectedID: UUID? = nil, refreshEditor: Bool = true) {
        do {
            try value.validate(duration: duration)
            guard value != track else { message.stringValue = "変更は自動保存されます。"; return }
            let assetsChanged = track.assets != value.assets
            if refreshEditor || selectedID != self.selectedID { drafts.removeAll() }
            track = value; self.selectedID = selectedID
            if let selectedID { selectedSlot = value.slot(of: selectedID) ?? selectedSlot }
            timeline?.images = value; timeline?.selectedImageID = selectedID; timeline?.selectedSlot = selectedSlot
            if refreshEditor { refreshSelection() }
            message.stringValue = "変更は自動保存されます。"
            onChange?(value)
            if assetsChanged { refreshAssets() }
        } catch { report(error) }
    }
    func report(_ error: Error) { message.stringValue = error.localizedDescription; manager?.showError(error) }
    func finishEditing() -> Bool {
        guard !processing else { return false }
        cancelValueDrag()
        if let editor = view.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        changePlacement()
        guard timingIsValid else { return false }
        guard view.window?.makeFirstResponder(nil) != false else { return false }
        drafts.removeAll()
        refreshAnimationValues()
        refreshGraphControls(resetRange: true)
        return true
    }
    func controlTextDidBeginEditing(_ obj: Notification) { onBeginTextEditing?() }

    private func bindTimingFields() {
        for (field, isStart) in [(start, true), (end, false)] {
            field.bindClipTime(isStart: isStart, interval: { [weak self] in
                self?.track.clip(self?.selectedID).map { ($0.start, $0.end) }
            }, duration: { [weak self] in self?.duration ?? 0 }, commit: { [weak self] in self?.finishTimingEdit() })
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if let parameter = valueFields.first(where: { $0.value === field })?.key {
            drafts[parameter] = field.stringValue
        } else if field === start || field === end {
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            changePlacement()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === start || field === end {
            finishTimingEdit()
        } else {
            onEndTextEditing?()
        }
    }

    private func finishTimingEdit() {
        changePlacement()
        refreshSelection()
        onEndTextEditing?()
    }

    @discardableResult
    func cancelValueDrag() -> Bool {
        guard let drag = valueDrag else { return false }
        valueDrag = nil
        drag.field.cancelTracking()
        timeline?.automationPreview = nil
        if case let .base(parameter) = drag.target, let draft = drafts[parameter] {
            drag.field.stringValue = draft
        }
        refreshAnimationValues()
        refreshGraphControls(resetRange: true)
        onPreview?(track)
        return true
    }

    func cancelAnimationInput(_ responder: NSTextView) -> Bool {
        let valueField = valueFields.first { $0.value.currentEditor() === responder }
        guard valueField != nil || minimum.currentEditor() === responder || maximum.currentEditor() === responder else { return false }
        guard view.window?.makeFirstResponder(nil) != false else { return false }
        if let valueField { drafts[valueField.key] = nil }
        refreshAnimationValues()
        refreshGraphControls(resetRange: true)
        return true
    }

    @objc private func changePlacement() {
        guard available, !refreshing, !processing, var clip = track.clip(selectedID) else { return }
        guard let begin = Double(start.stringValue), let finish = Double(end.stringValue),
              begin.isFinite, finish.isFinite, begin >= 0, finish <= duration else {
            timingIsValid = false; message.stringValue = "開始・終了を秒数で入力してください。"; return
        }
        if begin != clip.start { clip.trimStart(to: max(0, snapGrid.nearest(begin))) }
        if finish != clip.end { clip.end = max(0, snapGrid.nearest(finish)) }
        do {
            let value = try track.updating(clip, slot: slot.indexOfSelectedItem + 1, duration: duration)
            timingIsValid = true
            commit(value, selectedID: clip.id, refreshEditor: false)
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

private extension ImageEditor {
    private func parameterControls(_ parameter: ImageParameter) -> NSStackView {
        let label = NSTextField(labelWithString: parameter.title)
        label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let field = DragValueField(frame: .zero)
        field.stringValue = String(parameter.defaultValue)
        connectValueField(field) { .base(parameter) }
        field.identifier = NSUserInterfaceItemIdentifier("images.value." + parameter.rawValue)
        field.delegate = self; field.target = self; field.action = #selector(confirmBaseValue(_:))
        field.toolTip = "固定値・基準値。ダブルクリックで入力、左右ドラッグで調整、ホイールクリックで初期値"
        field.widthAnchor.constraint(equalToConstant: 66).isActive = true
        let unit = NSTextField(labelWithString: parameter.unit)
        unit.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let button = NSButton(title: "◇", target: self, action: #selector(addKey(_:)))
        button.tag = ImageParameter.allCases.firstIndex(of: parameter)!
        button.identifier = NSUserInterfaceItemIdentifier("images.key." + parameter.rawValue)
        button.toolTip = parameter.title + "のキーを打つ"
        button.setAccessibilityLabel(button.toolTip)
        valueFields[parameter] = field
        clipControls += [field, button]
        let group = row([label, field, unit, button])
        group.spacing = 5
        return group
    }
    @objc private func changeAutomatic() {
        guard automatic.isEnabled, var clip = track.clip(selectedID) else { return }
        clip.automaticAnimation = AutomaticAnimation.allCases[automatic.indexOfSelectedItem]
        clip.pulseAmount = amount.doubleValue / 100
        commitAnimation(clip, refreshEditor: false)
        amountLabel.stringValue = String(format: "%.1f%%", amount.doubleValue)
        amount.isEnabled = clip.automaticAnimation != .off
    }

    private func refreshAnimationValues() {
        let clip = track.clip(selectedID)
        for (parameter, field) in valueFields {
            let title = clip?.curve(parameter) == nil ? "固定値" : "基準値"
            field.setAccessibilityLabel(parameter.title + "の" + title)
            field.toolTip = title + "。ダブルクリックで入力、左右ドラッグで調整、ホイールクリックで初期値"
            guard field.currentEditor() == nil, drafts[parameter] == nil else { continue }
            let value = clip?.baseValue(parameter) ?? parameter.defaultValue
            let text = String(value)
            if field.stringValue != text { field.stringValue = text }
        }
    }

    private func refreshGraphControls(resetRange: Bool = false) {
        let clip = (valueDrag?.preview ?? track).clip(selectedID)
        let parameters = ImageParameter.allCases.filter { clip?.curve($0) != nil }
        if parameters != graphParameters {
            graphParameters = parameters
            graphParameter.removeAllItems()
            graphParameter.addItems(withTitles: parameters.map(\.title))
        }
        let active = timeline?.selectedParameter ?? parameters.first
        let curve = active.flatMap { clip?.curve($0) }
        if let active { graphParameter.selectItem(withTitle: active.title) }
        let enabled = automatic.isEnabled
        graphParameter.isEnabled = enabled && !parameters.isEmpty
        for field in [minimum, maximum] { field.isEnabled = enabled && curve != nil }
        let minimumText = curve.map { String($0.minimum) } ?? ""
        let maximumText = curve.map { String($0.maximum) } ?? ""
        if resetRange || rangeParameter != active || minimum.currentEditor() == nil { minimum.stringValue = minimumText }
        if resetRange || rangeParameter != active || maximum.currentEditor() == nil { maximum.stringValue = maximumText }
        rangeParameter = active
    }

    @objc private func confirmBaseValue(_ field: NSTextField) {
        guard field.isEnabled, let parameter = valueFields.first(where: { $0.value === field })?.key,
              var clip = track.clip(selectedID) else { return }
        guard let value = Double(field.stringValue), parameter.accepts(value) else {
            report(StudioError.message("変形の値を数値で入力してください。拡大率には正の値が必要です。")); return
        }
        clip.setBaseValue(value, for: parameter)
        if commitAnimation(clip) {
            drafts[parameter] = nil
            refreshAnimationValues()
        }
    }

    @objc private func addKey(_ button: NSButton) {
        guard button.isEnabled, var clip = track.clip(selectedID) else { return }
        let parameter = ImageParameter.allCases[button.tag]
        guard let field = valueFields[parameter],
              (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let curve = clip.curve(parameter)
        if curve == nil {
            let input = field.currentEditor()?.string ?? drafts[parameter] ?? field.stringValue
            guard let value = Double(input), parameter.accepts(value) else {
                report(StudioError.message("キーの値を数値で入力してください。拡大率には正の値が必要です。")); return
            }
            clip.setBaseValue(value, for: parameter)
        }
        onBeginEdit?()
        guard currentTime >= clip.start, currentTime <= clip.end else {
            report(StudioError.message("選択した画像クリップ内に再生位置を合わせてください。")); return
        }
        let existing = curve?.key(near: currentTime - clip.start)
        let time = existing.map { clip.start + $0.time }
            ?? clip.keyTime(at: currentTime, grid: keySnap.state == .on ? snapGrid : nil)
        let id = clip.setKey(parameter, at: time, value: clip.manualValue(parameter, at: time))
        if commitAnimation(clip) {
            drafts[parameter] = nil
            if curve == nil { timeline?.revealAutomation(in: selectedSlot) }
            timeline?.selectGraph(parameter, key: id, reveal: true)
            let keyTime = clip.curve(parameter)?.keys.first { $0.id == id }.map { clip.start + $0.time }
            onSeek?(keyTime ?? time)
            refreshAnimationValues()
        }
    }

    private func connectValueField(_ field: DragValueField, target: @escaping () -> ValueTarget?) {
        field.onDragStart = { [weak self, weak field] in
            guard let self, let field, let target = target(),
                  let clip = self.track.clip(self.selectedID), let initial = target.value(in: clip) else { return false }
            self.onBeginEdit?()
            self.valueDrag = ValueDrag(target: target, field: field, original: clip, initial: initial)
            return true
        }
        field.onDragChange = { [weak self] distance in self?.updateValueDrag(distance) }
        field.onDragEnd = { [weak self] in self?.finishValueDrag() }
        field.onReset = { [weak self] in
            guard let self, let target = target(), var clip = self.track.clip(self.selectedID) else { return }
            self.cancelValueDrag()
            target.apply(target.initialValue, to: &clip, resetting: true)
            self.onBeginEdit?()
            if self.commitAnimation(clip) {
                self.drafts[target.parameter] = nil
                self.refreshAnimationValues()
                self.refreshGraphControls(resetRange: true)
            }
        }
    }

    private func updateValueDrag(_ distance: Double) {
        guard var drag = valueDrag, let slot = track.slot(of: drag.original.id) else { return }
        var clip = drag.original
        let parameter = drag.target.parameter
        let value = drag.initial + distance.rounded()
        guard parameter.accepts(value) else { return }
        drag.target.apply(value, to: &clip)
        guard let preview = try? track.updating(clip, slot: slot, duration: duration) else { return }
        drag.preview = preview
        valueDrag = drag
        drag.field.stringValue = String(value)
        if rangeParameter == parameter, let curve = clip.curve(parameter) {
            minimum.stringValue = String(curve.minimum)
            maximum.stringValue = String(curve.maximum)
        }
        timeline?.automationPreview = preview
        onPreview?(preview)
    }

    private func finishValueDrag() {
        guard let drag = valueDrag else { return }
        valueDrag = nil
        timeline?.automationPreview = nil
        if let preview = drag.preview, preview != track {
            commit(preview, selectedID: drag.original.id)
        } else {
            refreshAnimationValues()
            refreshGraphControls(resetRange: true)
            onPreview?(track)
        }
    }

    @objc private func changeKeySnap() { timeline?.keySnapEnabled = keySnap.state == .on }

    @objc private func changeGraphParameter() {
        guard graphParameters.indices.contains(graphParameter.indexOfSelectedItem) else { return }
        timeline?.selectGraph(graphParameters[graphParameter.indexOfSelectedItem], reveal: true)
    }

    @objc private func changeGraphRange() {
        guard minimum.isEnabled, let parameter = rangeParameter, var clip = track.clip(selectedID),
              var curve = clip.curve(parameter) else { return }
        guard let minValue = Double(minimum.stringValue), let maxValue = Double(maximum.stringValue),
              parameter.accepts(minValue), parameter.accepts(maxValue), minValue < maxValue,
              (maxValue - minValue).isFinite else {
            report(StudioError.message("最小値は最大値より小さくしてください。拡大率には正の値が必要です。")); return
        }
        curve.minimum = minValue
        curve.maximum = maxValue
        clip.setCurve(curve)
        commitAnimation(clip)
    }

    @discardableResult
    private func commitAnimation(_ clip: ImageClip, refreshEditor: Bool = true) -> Bool {
        do {
            guard let slot = track.slot(of: clip.id) else { return false }
            commit(try track.updating(clip, slot: slot, duration: duration), selectedID: clip.id, refreshEditor: refreshEditor)
            return true
        } catch { report(error); return false }
    }
}
