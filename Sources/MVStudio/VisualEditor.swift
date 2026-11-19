import AppKit
import UniformTypeIdentifiers

@MainActor
final class VisualEditor: NSViewController, NSTextFieldDelegate {
    var onSelectionChange: ((UUID?) -> Void)?
    var onProcessing: ((Bool) -> Void)?
    var onAssetsReload: (() -> Void)?
    var onBeginTextEditing: (() -> Void)?
    var onEndTextEditing: (() -> Void)?
    var onChange: ((VisualTrack) -> Void)?
    var onPreview: ((VisualTrack) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onBeginEdit: (() -> Void)?
    var currentTime = 0.0 { didSet { effectsEditor.time = currentTime } }
    private let effectsEditor = ImageEffectsEditor()
    var duration = 0.0
    var snapGrid = TimelineSnapGrid()
    var timeline: TimelineView? { didSet { connectTimeline() } }
    private(set) var track = VisualTrack()
    private(set) var projectURL: URL?
    private(set) var thumbnails: [UUID: NSImage] = [:]
    private(set) var missing = Set<UUID>()
    let store = VisualAssetLoader()
    private var generation = UUID()
    private var assetRefreshRevision = 0
    private var available = false
    private var processing = false
    var isProcessing: Bool { processing }
    private var refreshing = false
    private var timingIsValid = true
    private var selectedID: UUID?
    private var selectedLayerID = UUID()
    private let name = NSTextField(labelWithString: "素材行を選択し、画像・動画・Spineを配置してください")
    private let start = DragValueField(frame: .zero)
    private let end = DragValueField(frame: .zero)
    private let sourceIn = DragValueField(frame: .zero)
    private let playbackSpeed = DragValueField(frame: .zero)
    private let speedRow = NSStackView()
    private let sourceRow = NSStackView()
    private let spineRow = NSStackView()
    private let spineLabel = NSTextField(labelWithString: "アニメーション")
    private let spineAutomation = NSButton(title: "オートメーションを作成", target: nil, action: nil)
    private let spineBlendRow = NSStackView()
    private let spineMaximum = NSPopUpButton()
    private let spineWeight = DragValueField(frame: .zero)
    private let spineAnimation = NSPopUpButton()
    private let spineLoop = NSButton(checkboxWithTitle: "ループ", target: nil, action: nil)
    private let layerID = NSPopUpButton()
    let musicEditor = AudioModulationEditor(frame: .zero)
    private let keySnap = NSButton(checkboxWithTitle: "制御点スナップ", target: nil, action: nil)
    private let graphParameter = NSPopUpButton()
    private let minimum = DragValueField(frame: .zero)
    private let maximum = DragValueField(frame: .zero)
    private var valueFields: [ImageParameter: DragValueField] = [:]
    private var handlePreview: VisualTrack?
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

        func value(in clip: VisualClip) -> Double? {
            switch self {
            case .base: return clip.baseValue(parameter)
            case .minimum: return clip.displayCurve(parameter)?.minimum
            case .maximum: return clip.displayCurve(parameter)?.maximum
            }
        }

        func apply(_ value: Double, to clip: inout VisualClip, resetting: Bool = false) {
            switch self {
            case .base:
                clip.setBaseValue(value, for: parameter, resetting: resetting)
            case .minimum, .maximum:
                guard var curve = clip.displayCurve(parameter) else { return }
                if case .minimum = self {
                    curve.minimum = value
                    if resetting, curve.maximum <= value { curve.maximum = parameter.defaultRange.upperBound }
                } else {
                    curve.maximum = value
                    if resetting, curve.minimum >= value { curve.minimum = parameter.defaultRange.lowerBound }
                }
                clip.setDisplayCurve(curve)
            }
        }
    }

    private struct ValueDrag {
        let target: ValueTarget
        let field: DragValueField
        let original: VisualClip
        let initial: Double
        var preview: VisualTrack?
    }
    private var drafts: [ImageParameter: String] = [:]
    private var graphParameters: [ImageParameter] = []
    private var rangeParameter: ImageParameter?
    private let message = NSTextField(labelWithString: "画像・動画・Spineを空白へドロップするか、ボタンで配置できます")
    private var controls: [NSControl] = []
    private weak var placementButton: NSButton?
    private var clipControls: [NSControl] = []
    private var manager: VisualAssetManager?
    private var importTask: Task<Void, Never>?

    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 6; view = root
        let add = NSButton(title: "＋素材を配置…", target: self, action: #selector(addImage))
        placementButton = add
        let remove = NSButton(title: "配置を削除", target: self, action: #selector(removeClip))
        let manage = NSButton(title: "素材管理…", target: self, action: #selector(openManager))
        let replace = NSButton(title: "素材を変更…", target: self, action: #selector(changeImage))
        start.delegate = self; end.delegate = self; sourceIn.delegate = self
        sourceIn.identifier = NSUserInterfaceItemIdentifier("visual.sourceIn")
        sourceIn.stringValue = "0"
        sourceIn.widthAnchor.constraint(equalToConstant: 100).isActive = true
        sourceRow.addArrangedSubview(NSTextField(labelWithString: "素材開始（秒）")); sourceRow.addArrangedSubview(sourceIn)
        sourceIn.bindNumber(step: 0.01, current: { [weak self] in self?.track.clip(self?.selectedID)?.content.sourceIn }, initial: { 0 }, normalize: { max(0, $0) }, commit: { [weak self] _ in self?.finishTimingEdit() })
        playbackSpeed.contextMenuProvider = { [weak self] in self?.makePlaybackSpeedMenu() ?? NSMenu() }
        playbackSpeed.delegate = self
        playbackSpeed.identifier = NSUserInterfaceItemIdentifier("visual.playbackSpeed")
        playbackSpeed.stringValue = "1"
        playbackSpeed.knobRange = VisualClip.playbackSpeedRange
        playbackSpeed.knobInitialValue = 1
        playbackSpeed.widthAnchor.constraint(equalToConstant: 100).isActive = true
        speedRow.addArrangedSubview(NSTextField(labelWithString: "再生速度（倍）"))
        speedRow.addArrangedSubview(playbackSpeed)
        playbackSpeed.bindNumber(step: 0.01, current: { [weak self] in self?.track.clip(self?.selectedID)?.content.speed }, initial: { 1 }, normalize: { min(VisualClip.playbackSpeedRange.upperBound, max(VisualClip.playbackSpeedRange.lowerBound, $0)) }, commit: { [weak self] _ in self?.finishTimingEdit() })
        spineAnimation.identifier = NSUserInterfaceItemIdentifier("visual.spine.animation")
        spineLoop.identifier = NSUserInterfaceItemIdentifier("visual.spine.loop")
        spineAnimation.target = self; spineAnimation.action = #selector(changeSpine)
        spineLoop.target = self; spineLoop.action = #selector(changeSpine)
        spineAutomation.identifier = NSUserInterfaceItemIdentifier("visual.spine.automation")
        spineAutomation.target = self; spineAutomation.action = #selector(createSpineAutomation)
        spineRow.addArrangedSubview(spineLabel)
        spineRow.addArrangedSubview(spineAnimation); spineRow.addArrangedSubview(spineLoop); spineRow.addArrangedSubview(spineAutomation)
        spineMaximum.identifier = NSUserInterfaceItemIdentifier("visual.spine.maximum")
        spineMaximum.target = self; spineMaximum.action = #selector(changeSpine)
        spineWeight.identifier = NSUserInterfaceItemIdentifier("visual.spine.weight")
        spineWeight.widthAnchor.constraint(equalToConstant: 90).isActive = true
        spineWeight.knobRange = 0...100; spineWeight.knobInitialValue = 0
        spineWeight.delegate = self; spineWeight.target = self; spineWeight.action = #selector(commitSpineWeight)
        spineWeight.bindNumber(current: { [weak self] in
            guard case let .blend(value) = self?.track.clip(self?.selectedID)?.content.spinePlayback?.mode else { return nil }
            return value.baseWeight * 100
        }, initial: { 0 }, normalize: { min(100, max(0, $0)) }, preview: { [weak self] in self?.setSpineWeight($0, preview: true) }, commit: { [weak self] in self?.setSpineWeight($0, preview: false) })
        for child in [NSTextField(labelWithString: "B（100%）"), spineMaximum, NSTextField(labelWithString: "基準%"), spineWeight] { spineBlendRow.addArrangedSubview(child) }
        for popup in [spineAnimation, spineMaximum] { popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        start.stringValue = "0"; end.stringValue = "2"
        bindTimingFields()
        start.identifier = NSUserInterfaceItemIdentifier("visuals.start"); end.identifier = NSUserInterfaceItemIdentifier("visuals.end")
        for field in [start, end] { field.widthAnchor.constraint(equalToConstant: 100).isActive = true }

        layerID.target = self; layerID.action = #selector(changePlacement)
        keySnap.state = .on
        keySnap.identifier = NSUserInterfaceItemIdentifier("visuals.keySnap")
        keySnap.target = self; keySnap.action = #selector(changeKeySnap)
        keySnap.toolTip = "制御点をタイムラインで選んだ音符の位置またはクリップの端に揃えます"
        graphParameter.target = self; graphParameter.action = #selector(changeGraphParameter)
        for (field, id) in [(minimum, "minimum"), (maximum, "maximum")] {
            field.identifier = NSUserInterfaceItemIdentifier("visuals.graph." + id)
            field.delegate = self; field.target = self; field.action = #selector(changeGraphRange)
            field.toolTip = DragValueField.numberEditingHint
            connectValueField(field) { [weak self, weak field] in
                guard let self, let parameter = self.rangeParameter else { return nil }
                return field === self.minimum ? .minimum(parameter) : .maximum(parameter)
            }
            field.widthAnchor.constraint(equalToConstant: 82).isActive = true
        }
        let toolbar = row([add, remove, manage])
        let selection = row([name, replace])
        let timing = NSStackView(views: [
            row([NSTextField(labelWithString: "開始"), start, NSTextField(labelWithString: "終了"), end]),
            row([NSTextField(labelWithString: "レイヤー"), layerID])
        ])
        timing.orientation = .vertical
        timing.alignment = .leading
        timing.spacing = 4
        let effect = row([keySnap])
        let horizontal = row([parameterControls(.x), parameterControls(.y)])
        let vertical = row([parameterControls(.scale), parameterControls(.rotation)])
        let opacity = row([parameterControls(.opacity)])
        let graphs = row([NSTextField(labelWithString: "グラフ"), graphParameter, NSTextField(labelWithString: "最小"), minimum,
                          NSTextField(labelWithString: "最大"), maximum])
        graphParameter.widthAnchor.constraint(equalToConstant: 94).isActive = true
        graphs.toolTip = "グラフの表示範囲を指定し、Returnで確定します"
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor; message.lineBreakMode = .byTruncatingTail
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for child in [toolbar, selection, timing, sourceRow, speedRow, spineRow, spineBlendRow, effect, horizontal, vertical, opacity, graphs, musicEditor, effectsEditor, message] { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        musicEditor.onCommit = { [weak self] parameter, modulation in self?.setMusic(parameter, modulation: modulation, preview: false) }
        musicEditor.onPreview = { [weak self] parameter, modulation in
            guard let self else { return }
            if let modulation { self.setMusic(parameter, modulation: modulation, preview: true) }
            else { self.timeline?.automationPreview = nil; self.onPreview?(self.track) }
        }
        musicEditor.onSelect = { [weak self] parameter in
            guard let self, self.track.clip(self.selectedID)?.displayCurve(parameter) != nil else { return }
            self.timeline?.selectGraph(parameter, reveal: true)
        }
        effectsEditor.onImportParticle = { [weak self] node, url in self?.importFile(url, particleNode: node) }
        effectsEditor.handleTarget = { [weak self] parameter in self?.previewHandleTarget(for: parameter) }
        effectsEditor.onEditMusic = { [weak self] parameter in self?.editMusic(parameter) }
        effectsEditor.onRemoveMusic = { [weak self] parameter in self?.setMusic(parameter, modulation: nil, preview: false) }
        effectsEditor.onDeleteEmitter = { [weak self] effects, index in self?.applyEffects(effects, preview: false, deletedEmitter: index) }
        effectsEditor.onCreateAutomation = { [weak self] in self?.createAutomation($0) }
        effectsEditor.onRemoveAutomation = { [weak self] in self?.removeAutomation($0) }
        effectsEditor.onCommit = { [weak self] effects in self?.applyEffects(effects, preview: false) }
        effectsEditor.onPreview = { [weak self] effects in
            guard let self else { return }
            if let effects { self.applyEffects(effects, preview: true) }
            else { self.onPreview?(self.track) }
        }
        clipControls += [remove, replace, start, end, sourceIn, playbackSpeed, spineAnimation, spineLoop, spineAutomation, spineMaximum, spineWeight, layerID, graphParameter, minimum, maximum]
        controls = [add, manage, keySnap] + clipControls
        refreshControls()
    }
    private func row(_ views: [NSView]) -> NSStackView { let row = NSStackView(views: views); row.spacing = 10; return row }
    private func connectTimeline() {
        timeline?.onSpineLaneAction = { [weak self] in self?.editSpineLane($0) }
        timeline?.onLayerAction = { [weak self] in self?.performLayerAction($0, $1) }
        timeline?.onLayerPreview = { [weak self] value in
            guard let self else { return }
            self.effectsEditor.updateLayerContext(value.clip(self.selectedID), track: value)
        }
        timeline?.onLayerCommit = { [weak self] in self?.commitLayers($0, selectedLayer: $1) }
        timeline?.onImageSelect = { [weak self] id, layerID in self?.select(id, layerID: layerID) }
        timeline?.onImagePreview = { [weak self] value in self?.onPreview?(value) }
        timeline?.onImageCommit = { [weak self] value, id in self?.commit(value, selectedID: id) }
        timeline?.onGraphSelection = { [weak self] in
            guard let self else { return }
            self.refreshGraphControls()
            if let parameter = self.timeline?.selectedParameter, self.musicEditor.parameter != parameter { self.musicEditor.select(parameter, notify: false) }
        }
        timeline?.onGraphRangeEdit = { [weak self] editingMaximum in
            guard let self else { return }
            let field = editingMaximum ? self.maximum : self.minimum
            if field.isEnabled { field.selectText(nil) }
        }
        timeline?.keySnapEnabled = keySnap.state == .on
        timeline?.onCreateEmptyClip = { [weak self] layerID, time in
            guard let self, self.available, self.finishEditing() else { return }
            do {
                let result = try self.track.addingEmpty(at: time, layerID: layerID, duration: self.duration, grid: self.snapGrid)
                self.onBeginEdit?()
                self.selectedLayerID = layerID
                self.commit(result.track, selectedID: result.clip.id)
            } catch { self.report(error) }
        }
        timeline?.onDropImage = { [weak self] url, layerID, time in self?.importFile(url, placement: (layerID, time)) }
        timeline?.visuals = track
    }
    func load(_ value: VisualTrack, projectURL: URL?) {
        timeline?.resetGraphDisclosure()
        replaceTrack(value, projectURL: projectURL)
    }
    private func replaceTrack(_ value: VisualTrack, projectURL: URL?) {
        cancelValueDrag()
        generation = UUID(); importTask?.cancel(); processing = false; onProcessing?(false)
        drafts.removeAll()
        track = value; self.projectURL = projectURL; selectedID = nil; selectedLayerID = value.layers[0].id
        thumbnails = [:]; missing = []; timeline?.visuals = value; timeline?.selectedImageID = nil; timeline?.selectedLayerID = value.layers[0].id
        refreshSelection(); refreshAssets()
    }
    var managerWindow: NSWindow? { manager?.window }
    func restore(_ value: VisualTrack) {
        let selection = selectedID ?? value.clips.first(where: { candidate in track.clip(candidate.id) == nil })?.id, layerID = selectedLayerID
        let parameter = timeline?.selectedParameter
        let key = timeline?.selectedKeyID
        replaceTrack(value, projectURL: projectURL)
        selectedID = value.clip(selection)?.id; selectedLayerID = selectedID.flatMap { value.layerID(of: $0) } ?? (value.layer(layerID) != nil ? layerID : value.layers[0].id)
        refreshSelection(); manager?.reload()
        if let parameter, let curve = value.clip(selectedID)?.displayCurve(parameter) {
            timeline?.selectGraph(parameter, key: curve.keys.first { $0.id == key }?.id, reveal: true)
        }
    }
    func setAvailable(_ value: Bool) {
        if !value { cancelValueDrag() }
        available = value
        refreshControls()
    }
    private func syncParticleThumbnails() {
        effectsEditor.particleThumbnails = thumbnails
        effectsEditor.missingParticleImages = missing
    }
    private func refreshControls() {
        onSelectionChange?(selectedID)
        controls.forEach { $0.isEnabled = available && !processing && manager == nil }
        placementButton?.isEnabled = available && !processing && manager == nil && track.canEdit(selectedLayerID)
        clipControls.forEach { $0.isEnabled = available && !processing && manager == nil && track.clip(selectedID) != nil && track.canEdit(selectedLayerID) }
        timeline?.isEnabled = available && !processing && manager == nil
        refreshGraphControls()
        syncParticleThumbnails()
        effectsEditor.load(track.clip(selectedID), editable: available && !processing && manager == nil && track.canEdit(selectedLayerID), track: track)
        sourceRow.isHidden = track.clip(selectedID)?.content.sourceIn == nil
        sourceIn.isEnabled = sourceIn.isEnabled && !sourceRow.isHidden
        speedRow.isHidden = track.clip(selectedID)?.content.isVideo != true
        playbackSpeed.isEnabled = sourceIn.isEnabled && !speedRow.isHidden
        spineRow.isHidden = track.clip(selectedID)?.content.spinePlayback == nil
        if case .blend = track.clip(selectedID)?.content.spinePlayback?.mode { spineBlendRow.isHidden = false }
        else { spineBlendRow.isHidden = true }
        musicEditor.load(track.clip(selectedID), editable: available && !processing && manager == nil && track.canEdit(selectedLayerID))
    }
    private func applyEffects(_ effects: ImageEffects, preview: Bool, deletedEmitter: Int? = nil) {
        guard available, !processing, manager == nil, var clip = track.clip(selectedID),
              let layerID = track.layerID(of: clip.id) else { return }
        if let deletedEmitter {
            clip.removeEmitterAutomation(at: deletedEmitter)
        }
        let original = clip
        var incoming = effects
        for node in clip.effects?.allNodes ?? [] {
            incoming.editNode(node.id) {
                $0.curves = node.curves; $0.audioModulations = node.audioModulations; $0.automationRanges = node.automationRanges
            }
        }
        clip.effects = incoming == ImageEffects() ? nil : incoming
        for parameter in ImageParameter.allCases {
            guard let effect = parameter.effect else { continue }
            guard let value = effect.read(effects) else {
                clip.removeAudioAndKeys(parameter)
                continue
            }
            if !(deletedEmitter != nil && parameter.rawValue.hasPrefix("emitter")),
               value != effect.read(original.effects ?? ImageEffects()) {
                clip.effects = effect.write(clip.effects ?? ImageEffects(), original.baseValue(parameter))
                clip.setBaseValue(value, for: parameter)
            }
        }
        do {
            let value = try track.updating(clip, layerID: layerID, duration: duration)
            if preview { onPreview?(value) }
            else {
                commit(value, selectedID: clip.id, refreshEditor: false)
                syncParticleThumbnails()
                effectsEditor.load(clip, editable: true, track: track)
                refreshGraphControls(resetRange: true)
            }
        } catch { report(error) }
    }

    private func select(_ id: UUID?, layerID: UUID) {
        cancelValueDrag()
        drafts.removeAll()
        selectedID = id; selectedLayerID = layerID; refreshSelection()
    }
    private func refreshSelection() {
        timingIsValid = true
        refreshing = true; defer { refreshing = false }
        layerID.removeAllItems()
        for (index, layer) in track.layers.reversed().enumerated() {
            layerID.addItem(withTitle: "\(index + 1). \(layer.name)")
            layerID.lastItem?.representedObject = layer.id
            layerID.lastItem?.isEnabled = !layer.isLocked
        }
        timeline?.selectedImageID = selectedID; timeline?.selectedLayerID = selectedLayerID
        if let clip = track.clip(selectedID) {
            name.stringValue = "\(track.layer(selectedLayerID)?.name ?? "レイヤー") / \(track.asset(clip.assetID)?.name ?? "空のクリップ")"
            start.stringValue = String(clip.start); end.stringValue = String(clip.end)
            sourceIn.stringValue = String(clip.content.sourceIn ?? 0)
            playbackSpeed.stringValue = String(clip.content.speed)
            spineAnimation.removeAllItems()
            if let descriptor = track.asset(clip.assetID)?.kind.spineDescriptor, let playback = clip.content.spinePlayback {
                spineAnimation.addItems(withTitles: descriptor.animations.map(\.name))
                spineAnimation.selectItem(withTitle: playback.animationName)
                spineLoop.state = playback.loop ? .on : .off
                spineAutomation.title = playback.hasLane ? "レーンを表示" : "オートメーションを作成"
                spineLabel.stringValue = playback.hasLane ? "基準" : "アニメーション"
                spineMaximum.removeAllItems(); spineMaximum.addItems(withTitles: descriptor.animations.map(\.name))
                if case let .blend(blend) = playback.mode {
                    spineLabel.stringValue = "A（0%）"; spineMaximum.selectItem(withTitle: blend.maximumAnimation)
                    spineWeight.doubleValue = blend.baseWeight * 100
                }
            }
            layerID.selectItem(at: Array(track.layers.reversed()).firstIndex { $0.id == selectedLayerID } ?? 0)
        } else { name.stringValue = "\(track.layer(selectedLayerID)?.name ?? "レイヤー")：空白へ画像・動画・Spineを配置してください" }
        refreshAnimationValues()
        refreshControls()
    }
    func commit(_ value: VisualTrack, selectedID: UUID? = nil, refreshEditor: Bool = true) {
        do {
            try value.validate(duration: duration)
            try value.validateEditing(from: track)
            guard value != track else { message.stringValue = "変更は自動保存されます。"; return }
            let assetsChanged = track.assets != value.assets
            if refreshEditor || selectedID != self.selectedID { drafts.removeAll() }
            track = value; self.selectedID = selectedID
            if value.layer(selectedLayerID) == nil { selectedLayerID = value.layers[0].id }
            if let selectedID { selectedLayerID = value.layerID(of: selectedID) ?? selectedLayerID }
            timeline?.visuals = value; timeline?.selectedImageID = selectedID; timeline?.selectedLayerID = selectedLayerID
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
        if let field = obj.object as? NSTextField, field === spineWeight {
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            commitSpineWeight(); return
        }
        guard let field = obj.object as? NSTextField else { return }
        if let parameter = valueFields.first(where: { $0.value === field })?.key {
            drafts[parameter] = field.stringValue
        } else if field === start || field === end || field === sourceIn || field === playbackSpeed {
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            changePlacement()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === start || field === end || field === sourceIn || field === playbackSpeed {
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
        let musicCancelled = musicEditor.cancelDrag()
        guard let drag = valueDrag else { return effectsEditor.cancelDrag() || musicCancelled }
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

    private func makePlaybackSpeedMenu() -> NSMenu {
        let menu = NSMenu()
        let current = track.clip(selectedID)?.content.speed
        for speed in [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0] {
            let item = menu.addItem(withTitle: "x\(speed)", action: #selector(choosePlaybackSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed
            item.state = current == speed ? .on : .off
        }
        return menu
    }

    @objc private func choosePlaybackSpeed(_ sender: NSMenuItem) {
        guard playbackSpeed.isEnabled, let speed = sender.representedObject as? Double else { return }
        playbackSpeed.cancelNumberDrag()
        onBeginEdit?()
        playbackSpeed.doubleValue = speed
        finishTimingEdit()
    }

    @objc private func changePlacement() {
        guard available, !refreshing, !processing, var clip = track.clip(selectedID) else { return }
        guard track.canEdit(selectedLayerID) else { timingIsValid = true; return }
        guard let begin = Double(start.stringValue), let finish = Double(end.stringValue),
              begin.isFinite, finish.isFinite, begin >= 0, finish <= duration else {
            timingIsValid = false; message.stringValue = "開始・終了を秒数で入力してください。"; return
        }
        if begin != clip.start {
            let newStart = max(0, snapGrid.nearest(begin))
            clip.end += newStart - clip.start; clip.start = newStart
            if finish == track.clip(selectedID)?.end { end.stringValue = String(clip.end) }
        }
        if finish != track.clip(selectedID)?.end { clip.end = max(0, snapGrid.nearest(finish)) }
        if clip.content.sourceIn != nil {
            guard let value = Double(sourceIn.stringValue), value.isFinite, value >= 0 else {
                timingIsValid = false; message.stringValue = "素材開始を0以上の秒数で入力してください。"; return
            }
            if clip.content.isVideo {
                guard let speed = Double(playbackSpeed.stringValue), speed.isFinite, VisualClip.playbackSpeedRange.contains(speed) else {
                    timingIsValid = false; message.stringValue = "再生速度を0.1〜16倍で入力してください。"; return
                }
                clip.end = clip.start + (clip.end - clip.start) * clip.content.speed / speed
                clip.content = .video(sourceIn: value, speed: speed)
            } else { clip.content.setSourceIn(value) }
        }
        do {
            let value = try track.updating(clip, layerID: (layerID.selectedItem?.representedObject as? UUID) ?? selectedLayerID, duration: duration)
            timingIsValid = true
            end.stringValue = String(clip.end)
            commit(value, selectedID: clip.id, refreshEditor: false)
            syncParticleThumbnails()
            effectsEditor.load(clip, editable: true, track: track)
        } catch { timingIsValid = false; report(error) }
    }

    @objc private func changeSpine() {
        guard available, !processing, !refreshing, var clip = track.clip(selectedID), var playback = clip.content.spinePlayback,
              let animation = spineAnimation.titleOfSelectedItem, let layerID = track.layerID(of: clip.id) else { return }
        onBeginEdit?()
        if case var .blend(blend) = playback.mode {
            guard let maximum = spineMaximum.titleOfSelectedItem, maximum != animation else { report(StudioError.message("異なる2つのアニメーションを選んでください。")); refreshSelection(); return }
            blend.minimumAnimation = animation; blend.maximumAnimation = maximum; playback.mode = .blend(blend)
        } else if playback.animationName != animation {
            if case .single = playback.mode { playback.sourceIn = 0 }
            playback.animationName = animation
        }
        playback.loop = spineLoop.state == .on; clip.content = .spine(playback)
        do { commit(try track.updating(clip, layerID: layerID, duration: duration), selectedID: clip.id) }
        catch { report(error); refreshSelection() }
    }

    @objc private func createSpineAutomation() {
        guard var playback = track.clip(selectedID)?.content.spinePlayback, let layerID = track.layerID(of: selectedID ?? UUID()) else { return }
        if !playback.hasLane {
            if case var .blend(blend) = playback.mode { blend.automated = true; playback.mode = .blend(blend) }
            else { playback.createSelection() }
            commitSpinePlayback(playback)
        }
        timeline?.revealAutomation(in: layerID)
    }

    private func commitSpinePlayback(_ playback: SpinePlayback, preview: Bool = false, editingWeight: Bool = false) {
        guard var clip = track.clip(selectedID), let layerID = track.layerID(of: clip.id) else { return }
        clip.content = .spine(playback)
        do {
            let value = try track.updating(clip, layerID: layerID, duration: duration)
            if preview { onPreview?(value) }
            else {
                if !editingWeight { onBeginEdit?() }
                commit(value, selectedID: clip.id, refreshEditor: !editingWeight)
            }
        } catch { report(error) }
    }

    private func setSpineWeight(_ percent: Double?, preview: Bool) {
        guard let percent else { onPreview?(track); return }
        guard percent.isFinite, (0...100).contains(percent), var playback = track.clip(selectedID)?.content.spinePlayback,
              case var .blend(blend) = playback.mode else { return }
        blend.baseWeight = percent / 100; playback.mode = .blend(blend)
        commitSpinePlayback(playback, preview: preview, editingWeight: spineWeight.currentEditor() != nil)
    }
    @objc private func commitSpineWeight() {
        guard let value = Double(spineWeight.stringValue), value.isFinite, (0...100).contains(value) else {
            report(StudioError.message("ブレンドの基準を0〜100%で入力してください。")); return
        }
        setSpineWeight(value, preview: false)
    }

    func editSpineLane(_ action: SpineLaneAction) {
        guard available, !processing, var playback = track.clip(selectedID)?.content.spinePlayback,
              let clip = track.clip(selectedID), let descriptor = track.asset(clip.assetID)?.kind.spineDescriptor else { return }
        let local = currentTime - clip.start
        switch action {
        case .remove: playback.removeLane(at: local)
        case .selection:
            if case .selection = playback.mode { return }
            if case let .blend(blend) = playback.mode {
                let alert = NSAlert(); alert.messageText = "ブレンドを削除してアニメーション切替にしますか？"
                alert.informativeText = "中間の混合率と制御点を削除します。Undoで戻せます。"
                let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
                popup.addItems(withTitles: [blend.minimumAnimation, blend.maximumAnimation]); popup.selectItem(at: blend.weight(at: local) < 0.5 ? 0 : 1)
                alert.accessoryView = popup; alert.addButton(withTitle: "切替に変更"); alert.addButton(withTitle: "キャンセル")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                playback.mode = .selection(base: popup.titleOfSelectedItem!, keys: [])
            } else { playback.createSelection() }
        case .blend:
            let names = descriptor.animations.map(\.name)
            guard names.count >= 2 else { report(StudioError.message("ブレンドには2つ以上のアニメーションが必要です。")); return }
            let alert = NSAlert(); alert.messageText = "2つのアニメーションでブレンド"
            let a = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28)), b = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
            a.addItems(withTitles: names); b.addItems(withTitles: names)
            let request = playback.resolved(at: local)
            a.selectItem(withTitle: request.animation)
            b.selectItem(withTitle: request.secondAnimation ?? names.first(where: { $0 != request.animation })!)
            let stack = NSStackView(views: [NSTextField(labelWithString: "A（最小・0%）"), a, NSTextField(labelWithString: "B（最大・100%）"), b]); stack.orientation = .vertical
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: 110); stack.alignment = .leading
            alert.accessoryView = stack; alert.addButton(withTitle: "ブレンドに変更"); alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn, let minimum = a.titleOfSelectedItem, let maximum = b.titleOfSelectedItem else { return }
            do { try playback.createBlend(minimum: minimum, maximum: maximum) }
            catch {
                guard minimum != maximum else { report(error); return }
                let confirm = NSAlert(); confirm.messageText = "既存キーを削除してブレンドを作成しますか？"; confirm.informativeText = error.localizedDescription
                confirm.addButton(withTitle: "既存キーを削除して作成"); confirm.addButton(withTitle: "キャンセル")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
                do { try playback.createBlend(minimum: minimum, maximum: maximum, discardingKeys: true) } catch { report(error); return }
            }
        }
        commitSpinePlayback(playback)
        if playback.hasLane, let layerID = track.layerID(of: clip.id) { timeline?.revealAutomation(in: layerID) }
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
            self.importFile(url, placement: (self.selectedLayerID, self.currentTime))
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
            let alert = NSAlert(); alert.messageText = "使用する素材"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
            popup.addItems(withTitles: track.assets.map { $0.name + (missing.contains($0.id) ? "（見つかりません）" : "") })
            alert.accessoryView = popup; alert.addButton(withTitle: "選択した素材を使用"); alert.addButton(withTitle: "ファイルから読み込む…"); alert.addButton(withTitle: "キャンセル")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { completion(track.assets[popup.indexOfSelectedItem].reference.resolve(projectURL: projectURL)); return }
            if response != .alertSecondButtonReturn { return }
        }
        if let url = Self.chooseFile() { completion(url) }
    }
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .png, .jpeg, .tiff, .mpeg4Movie, .quickTimeMovie, .movie]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    func importFile(_ url: URL, placement: (layerID: UUID, time: Double)? = nil, replacingAsset: UUID? = nil, replacingClip: UUID? = nil, particleNode: UUID? = nil) {
        guard available, !processing, let projectURL else { return }
        let particleClipID = particleNode == nil ? nil : selectedID
        if particleNode != nil {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { report(StudioError.message("粒子には静止画像を指定してください。")); return }
        }
        let atlasURL: URL?
        if url.pathExtension.lowercased() == "json" {
            let existing = track.assets.first { $0.reference.resolve(projectURL: projectURL).standardizedFileURL == url.standardizedFileURL }
            let candidate = existing?.kind.spineDescriptor?.atlasReference.resolve(projectURL: projectURL) ?? url.deletingPathExtension().appendingPathExtension("atlas")
            if FileManager.default.fileExists(atPath: candidate.path) { atlasURL = candidate }
            else {
                let panel = NSOpenPanel(); panel.title = "Spineのatlasファイルを選択"; panel.allowedContentTypes = [UTType(filenameExtension: "atlas") ?? .data]
                panel.directoryURL = url.deletingLastPathComponent(); panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let selected = panel.url else { return }
                atlasURL = selected
            }
        } else { atlasURL = nil }
        let token = generation
        onBeginEdit?(); processing = true; onProcessing?(true); refreshControls(); manager?.setProcessing(true)
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { processing = false; onProcessing?(false); refreshControls(); manager?.setProcessing(false) } }
            do {
                await store.invalidate()
                let inspected = try await store.inspect(url, atlasURL: atlasURL)
                try Task.checkCancellation()
                guard generation == token else { return }
                var value = track
                var selection = selectedID
                if let id = replacingAsset { value = try value.replacingAsset(id: id, url: url, projectURL: projectURL, kind: inspected.kind) }
                else {
                    let assetID = value.register(url: url, projectURL: projectURL, kind: inspected.kind)
                    if let nodeID = particleNode {
                        guard inspected.kind == .still, var clip = value.clip(particleClipID),
                              let node = clip.effects?.nodes.first(where: { $0.id == nodeID }), node.kind.supportsParticleImage else { throw StudioError.message("粒子画像の適用先が見つかりません。") }
                        var appearance = node.particleAppearance ?? ParticleAppearance()
                        appearance.assetID = assetID; appearance.mode = .image
                        clip.effects?.setAppearance(appearance, for: node.kind)
                        value = try value.updating(clip, layerID: value.layerID(of: clip.id)!, duration: duration)
                    } else if let placement {
                        let result = try value.adding(assetID: assetID, at: placement.time, layerID: placement.layerID, duration: duration, grid: snapGrid)
                        value = result.track; selection = result.clip.id
                    } else if let replacingClip, var clip = value.clip(replacingClip) {
                        guard (clip.assetID == nil ? inspected.kind == .still : track.asset(clip.assetID)?.kind.sameType(as: inspected.kind) == true), inspected.kind.accepts(clip.content) else { throw StudioError.message("同じ種類の素材で置き換えてください。") }
                        clip.assetID = assetID; value = try value.updating(clip, layerID: value.layerID(of: replacingClip)!, duration: duration)
                    } else if replacingClip != nil { throw StudioError.message("置き換える配置が見つかりません。") }
                }
                await store.invalidate()
                guard generation == token else { return }
                commit(value, selectedID: selection)
                onAssetsReload?(); refreshAssets()
                if let placement, let clip = value.clip(selection) { selectedLayerID = placement.layerID; onSeek?(clip.start) }
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
                let inspected = try? await store.inspect(asset.reference.resolve(projectURL: projectURL), maximumSize: 160, atlasURL: asset.kind.spineDescriptor?.atlasReference.resolve(projectURL: projectURL))
                let compatible = inspected.map { info in
                    info.kind.sameType(as: asset.kind)
                        && self.track.uses(asset.id).allSatisfy { clip in
                            guard info.kind.accepts(clip.content) else { return false }
                            guard clip.content.sourceIn != nil, let length = info.kind.videoDuration else { return true }
                            return clip.sourceEnd <= length + 1e-9
                        }
                } ?? false
                let image = compatible ? inspected?.thumbnail : nil
                guard generation == token, revision == assetRefreshRevision, track.asset(asset.id)?.reference == asset.reference else { continue }
                if let image { thumbnails[asset.id] = NSImage(cgImage: image, size: .zero); missing.remove(asset.id) }
                else { thumbnails[asset.id] = nil; missing.insert(asset.id) }
            }
            guard generation == token, revision == assetRefreshRevision else { return }
            timeline?.missingAssets = missing; manager?.reload()
            syncParticleThumbnails()
            effectsEditor.load(track.clip(selectedID), editable: available && !processing && manager == nil && track.canEdit(selectedLayerID), track: track)
        }
    }
    @objc func openManager() {
        guard available, !processing, manager == nil, finishEditing(), let window = view.window else { return }
        timeline?.cancelDrag(); onBeginEdit?()
        let controller = VisualAssetManager(editor: self)
        manager = controller; refreshControls()
        window.beginSheet(controller.window!) { [weak self] _ in self?.manager = nil; self?.refreshControls() }
    }
    func reloadAsset(_ id: UUID) {
        guard let asset = track.asset(id), let projectURL else { return }
        importFile(asset.reference.resolve(projectURL: projectURL), replacingAsset: id)
    }
    func deleteAsset(_ id: UUID, includingPlacements: Bool) {
        do { commit(try track.removingAsset(id: id, includingPlacements: includingPlacements), selectedID: selectedID); manager?.reload() }
        catch { report(error) }
    }
    func usageDescription(_ id: UUID) -> String {
        (track.particleUses(id).map { "粒子画像　画像\(track.layer(track.layerID(of: $0.id))?.name ?? "レイヤー")　\(TimelineGeometry.label($0.start))" } + track.uses(id).map { "画像\(track.layer(track.layerID(of: $0.id))?.name ?? "レイヤー")　\(TimelineGeometry.label($0.start))–\(TimelineGeometry.label($0.end))" }).joined(separator: "\n")
    }
}

private extension VisualEditor {
    private func parameterControls(_ parameter: ImageParameter) -> NSStackView {
        let field = DragValueField(frame: .zero)
        field.previewHandleProvider = { [weak self] in self?.previewHandleTarget(for: parameter) }
        let label = PreviewHandleLabel(parameter.title, field: field)
        label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        field.stringValue = String(parameter.defaultValue)
        field.knobInitialValue = parameter.defaultValue
        field.knobRange = parameter.valueRange
        connectValueField(field) { .base(parameter) }
        field.identifier = NSUserInterfaceItemIdentifier("visuals.value." + parameter.rawValue)
        field.delegate = self; field.target = self; field.action = #selector(confirmBaseValue(_:))
        field.toolTip = "固定値・基準値。\(DragValueField.numberEditingHint)"
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let unit = NSTextField(labelWithString: parameter.unit)
        unit.widthAnchor.constraint(equalToConstant: 16).isActive = true
        field.onCreateAutomation = { [weak self] in self?.createAutomation(parameter) }
        field.onRemoveAutomation = { [weak self] in self?.removeAutomation(parameter) }
        field.onEditMusic = { [weak self] in self?.editMusic(parameter) }
        field.onRemoveMusic = { [weak self] in self?.setMusic(parameter, modulation: nil, preview: false) }
        valueFields[parameter] = field
        clipControls.append(field)
        let group = row([label, field, unit])
        group.spacing = 5
        return group
    }
    private func editMusic(_ parameter: ImageParameter) {
        guard available, !processing, manager == nil, let clip = track.clip(selectedID) else { return }
        if clip.audioModulations[parameter] == nil { setMusic(parameter, modulation: .initial(for: parameter), preview: false) }
        musicEditor.select(parameter)
        view.window?.makeFirstResponder(nil)
        musicEditor.scrollToVisible(musicEditor.bounds)
    }

    private func setMusic(_ parameter: ImageParameter, modulation: AudioModulation?, preview: Bool) {
        guard available, !processing, manager == nil, var clip = track.clip(selectedID), let layerID = track.layerID(of: clip.id) else { return }
        clip.audioModulations[parameter] = modulation
        if modulation == nil { clip.automationRanges[parameter] = nil }
        do {
            let updated = try track.updating(clip, layerID: layerID, duration: duration)
            if preview { timeline?.automationPreview = updated; onPreview?(updated) }
            else {
                onBeginEdit?()
                commit(updated, selectedID: clip.id)
                if modulation != nil { timeline?.revealAutomation(in: layerID); timeline?.selectGraph(parameter, reveal: true) }
            }
        } catch { report(error) }
    }

    private func refreshAnimationValues() {
        let clip = track.clip(selectedID)
        for (parameter, field) in valueFields {
            field.hasAutomation = clip?.curve(parameter) != nil
            field.hasMusic = clip?.audioModulations[parameter] != nil
            let title = field.hasAutomation ? "基準値" : "固定値"
            field.setAccessibilityLabel(parameter.title + "の" + title)
            field.toolTip = title + "。\(DragValueField.numberEditingHint)。ノブまたは数値を右クリックでオートメーションを作成・削除"
            guard field.currentEditor() == nil, drafts[parameter] == nil else { continue }
            let value = clip?.baseValue(parameter) ?? parameter.defaultValue
            let text = String(value)
            if field.stringValue != text { field.stringValue = text }
        }
    }

    private func refreshGraphControls(resetRange: Bool = false) {
        let clip = (handlePreview ?? valueDrag?.preview ?? track).clip(selectedID)
        let parameters = ImageParameter.allCases.filter { clip?.displayCurve($0) != nil }
        if parameters != graphParameters {
            graphParameters = parameters
            graphParameter.removeAllItems()
            graphParameter.addItems(withTitles: parameters.map(\.title))
        }
        let active = timeline?.selectedParameter ?? parameters.first
        let curve = active.flatMap { clip?.displayCurve($0) }
        if let active { graphParameter.selectItem(withTitle: active.title) }
        let enabled = available && !processing && manager == nil && track.canEdit(selectedLayerID) && clip != nil
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

    private func createAutomation(_ parameter: ImageParameter) {
        guard var clip = track.clip(selectedID), clip.curve(parameter) == nil,
              available, !processing, manager == nil else { return }
        let field = valueFields[parameter]
        guard field?.isEnabled != false,
              (field?.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let input = field?.currentEditor()?.string ?? drafts[parameter] ?? field?.stringValue ?? String(clip.baseValue(parameter))
        guard let value = Double(input), parameter.accepts(value) else {
            report(StudioError.message("キーの値を数値で入力してください。拡大率には正の値が必要です。")); return
        }
        clip.setBaseValue(value, for: parameter)
        onBeginEdit?()
        guard currentTime >= clip.start, currentTime <= clip.end else {
            report(StudioError.message("選択した画像クリップ内に再生位置を合わせてください。")); return
        }
        let time = clip.keyTime(at: currentTime, grid: keySnap.state == .on ? snapGrid : nil)
        let id = clip.setKey(parameter, at: time, value: clip.manualValue(parameter, at: time))
        if commitAnimation(clip) {
            drafts[parameter] = nil
            timeline?.revealAutomation(in: selectedLayerID)
            timeline?.selectGraph(parameter, key: id, reveal: true)
            let keyTime = clip.curve(parameter)?.keys.first { $0.id == id }.map { clip.start + $0.time }
            onSeek?(keyTime ?? time)
            refreshAnimationValues()
        }
    }

    private func removeAutomation(_ parameter: ImageParameter) {
        guard available, !processing, manager == nil, valueFields[parameter]?.isEnabled != false else { return }
        cancelValueDrag()
        guard var clip = track.clip(selectedID), clip.curve(parameter) != nil else { return }
        if let curve = clip.curve(parameter), clip.audioModulations[parameter] != nil { clip.automationRanges[parameter] = VisualClip.DisplayRange(lower: curve.minimum, upper: curve.maximum) }
        clip.curves.removeAll { $0.parameter == parameter }
        onBeginEdit?()
        if commitAnimation(clip) {
            drafts[parameter] = nil
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
        guard var drag = valueDrag, let layerID = track.layerID(of: drag.original.id) else { return }
        var clip = drag.original
        let parameter = drag.target.parameter
        let value = drag.initial + distance.rounded()
        guard parameter.accepts(value) else { return }
        drag.target.apply(value, to: &clip)
        guard let preview = try? track.updating(clip, layerID: layerID, duration: duration) else { return }
        drag.preview = preview
        valueDrag = drag
        drag.field.stringValue = String(value)
        if rangeParameter == parameter, let curve = clip.displayCurve(parameter) {
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
              var curve = clip.displayCurve(parameter) else { return }
        guard let minValue = Double(minimum.stringValue), let maxValue = Double(maximum.stringValue),
              parameter.accepts(minValue), parameter.accepts(maxValue), minValue < maxValue,
              (maxValue - minValue).isFinite else {
            report(StudioError.message("最小値は最大値より小さくしてください。拡大率には正の値が必要です。")); return
        }
        curve.minimum = minValue
        curve.maximum = maxValue
        clip.setDisplayCurve(curve)
        commitAnimation(clip)
    }

    @discardableResult
    private func commitAnimation(_ clip: VisualClip, refreshEditor: Bool = true) -> Bool {
        do {
            guard let layerID = track.layerID(of: clip.id) else { return false }
            commit(try track.updating(clip, layerID: layerID, duration: duration), selectedID: clip.id, refreshEditor: refreshEditor)
            return true
        } catch { report(error); return false }
    }
}

@MainActor
extension VisualEditor {
    func previewHandleTarget(for parameter: ImageParameter) -> PreviewHandleTarget? {
        guard let pair = PreviewPositionPair.containing(parameter), let id = selectedID,
              let clip = track.clip(id), track.canEdit(track.layerID(of: id)), available, !processing, manager == nil,
              pair.enabled(clip.effects ?? ImageEffects()) else { return nil }
        if pair.x == .flareX, clip.effects?.lensFlare?.automaticMotion == true { return nil }
        let generation = self.generation
        let valid: () -> Bool = { [weak self] in
            guard let self, self.generation == generation, self.selectedID == id,
                  self.available, !self.processing, self.manager == nil, self.track.canEdit(self.track.layerID(of: id)), let clip = self.track.clip(id) else { return false }
            return pair.enabled(clip.effects ?? ImageEffects()) && !(pair.x == .flareX && clip.effects?.lensFlare?.automaticMotion == true)
        }
        return PreviewHandleTarget(id: id.uuidString + pair.x.rawValue, title: pair.title, coordinates: pair.coordinates,
            isValid: valid, isVisible: { [weak self] in
                guard valid(), let self, let clip = self.track.clip(id) else { return false }
                return clip.start <= self.currentTime && self.currentTime < clip.end
            }, position: { [weak self] in
                guard let self, let clip = (self.handlePreview ?? self.track).clip(id) else { return .zero }
                return pair.position(in: clip)
            }, evaluatedPosition: { [weak self] in
                guard let self, let clip = (self.handlePreview ?? self.track).clip(id) else { return .zero }
                return pair.evaluatedPosition(in: clip, at: self.currentTime,
                    settings: self.timeline?.sceneSettings ?? SceneSettings(), features: self.timeline?.audioFeatures)
            }, begin: { [weak self] in
                guard valid(), let self, let original = self.track.clip(id), let layerID = self.track.layerID(of: id) else { return nil }
                self.cancelValueDrag()
                let source = self.track
                var draft = source
                return PreviewHandleEdit(update: { [weak self] point in
                    guard let self, valid() else { return }
                    let clip = pair.moving(original, to: point)
                    guard let value = try? source.updating(clip, layerID: layerID, duration: self.duration) else { return }
                    draft = value; self.handlePreview = value
                    self.timeline?.automationPreview = value
                    self.showHandleValues(clip)
                    self.onPreview?(value)
                }, finish: { [weak self] commit in
                    guard let self else { return }
                    self.handlePreview = nil; self.timeline?.automationPreview = nil
                    if commit, valid(), draft != source { self.commit(draft, selectedID: id) }
                    else {
                        if let clip = self.track.clip(self.selectedID) { self.showHandleValues(clip) }
                        self.onPreview?(self.track)
                    }
                })
            })
    }

    private func showHandleValues(_ clip: VisualClip) {
        for (parameter, field) in valueFields where field.currentEditor() == nil { field.doubleValue = clip.baseValue(parameter) }
        syncParticleThumbnails()
        effectsEditor.load(clip, editable: available && !processing && manager == nil && track.canEdit(selectedLayerID), track: handlePreview ?? track)
        refreshGraphControls(resetRange: true)
    }
    private func commitLayers(_ value: VisualTrack, selectedLayer: UUID) {
        guard available, !processing, manager == nil, finishEditing() else { return }
        onBeginEdit?()
        selectedLayerID = selectedLayer
        commit(value, selectedID: value.layerID(of: selectedID ?? UUID()) == selectedLayer ? selectedID : nil)
        timeline?.revealLayer(selectedLayer)
    }
    func performLayerAction(_ id: UUID, _ action: VisualLayerAction) {
        guard available, !processing, manager == nil, finishEditing(), let layer = track.layer(id) else { return }
        do {
            var value = track
            var selection = selectedLayerID
            switch action {
            case .add(let above):
                let result = try track.addingLayer(relativeTo: id, above: above)
                value = result.track; selection = result.id
            case .move(let forward):
                let index = track.layers.firstIndex { $0.id == id }!
                let target = index + (forward ? 1 : -1)
                guard track.layers.indices.contains(target) else { return }
                value = try track.movingLayer(id, relativeTo: track.layers[target].id, above: forward)
            case .rename: timeline?.beginLayerRename(id); return
            case .delete:
                try track.requireEditable(id)
                guard track.layers.count > 1 else { return }
                if !layer.clips.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "「\(layer.name)」を削除しますか？"
                    alert.informativeText = "\(layer.clips.count)個のクリップも削除します。素材ファイルは残ります。"
                    alert.addButton(withTitle: "削除"); alert.addButton(withTitle: "キャンセル")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                let index = track.layers.firstIndex { $0.id == id }!
                if selection == id { selection = track.layers[index > 0 ? index - 1 : 1].id }
                value = try track.removingLayer(id)
            case .visibility: value = try track.editingLayer(id) { $0.isVisible.toggle() }
            case .lock: value = try track.editingLayer(id) { $0.isLocked.toggle() }
            }
            commitLayers(value, selectedLayer: selection)
        } catch { report(error) }
    }

}
