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
    var onBelowMaskGuideChange: ((Bool) -> Void)?
    var showsBelowMaskGuide: Bool { effectsEditor.showsBelowMaskGuide }
    var onSeek: ((Double) -> Void)?
    var onBeginEdit: (() -> Void)?
    var currentTime = 0.0 { didSet { effectsEditor.time = currentTime; updateInspectionStatus() } }
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
    private let graphSettings = NSStackView()
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
    let lfoEditor = LFOEditor(frame: .zero)
    let musicEditor = AudioModulationEditor(frame: .zero)
    private let keySnap = NSButton(checkboxWithTitle: "制御点スナップ", target: nil, action: nil)
    let inspectionHeader = NSStackView()
    private let clipKind = NSTextField(labelWithString: "")
    private let targetPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let targetPath = NSTextField(wrappingLabelWithString: "")
    private let targetStatus = NSTextField(wrappingLabelWithString: "")
    private let targetSummary = NSTextField(wrappingLabelWithString: "")
    private(set) var inspectionParameter: ImageParameter? = .scale
    private(set) var inspectionNodeID: UUID?
    private var inspectionClipID: UUID?
    private var rememberedParameters: [UUID: ImageParameter] = [:]
    private var synchronizingInspection = false
    let filterBar = NSStackView()
    private var revealSourceSettings = false
    private let filterControl = NSButton(checkboxWithTitle: "変更のみ", target: nil, action: nil)
    private let filterPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let filterNotice = NSTextField(wrappingLabelWithString: "")
    private let showAll = NSButton(title: "すべて表示", target: nil, action: nil)
    private var modifiedOnly = UserDefaults.standard.bool(forKey: InspectorFilter.defaultsKey)
    private var revealedParameter: ImageParameter?
    private var parameterGroups: [ImageParameter: NSView] = [:]
    private var transformRows: [NSStackView] = []
    private var transformSection: InspectorSection!
    private var effectsSection: InspectorSection!
    private var automationSection: InspectorSection!
    private var placementDetails: [NSView] = []
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
    private var rangeParameter: ImageParameter?
    private let message = NSTextField(labelWithString: "画像・動画・Spineをドロップして配置。同じ段で重ねるとクロスフェードします")
    private var controls: [NSControl] = []
    private let placementMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private var clipControls: [NSControl] = []
    private var manager: VisualAssetManager?
    private var importTask: Task<Void, Never>?

    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 12; view = root
        placementMenu.identifier = NSUserInterfaceItemIdentifier("visual.source.menu")
        placementMenu.toolTip = "素材と配置の操作"
        placementMenu.setAccessibilityLabel("素材と配置の操作")
        placementMenu.addItem(withTitle: "")
        placementMenu.item(at: 0)?.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "素材と配置の操作")
        placementMenu.menu?.autoenablesItems = false
        for (title, action) in [("＋素材を配置…", #selector(addImage)), ("配置を削除", #selector(removeClip)), ("素材を変更…", #selector(changeImage))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            placementMenu.menu?.addItem(item)
        }
        start.delegate = self; end.delegate = self; sourceIn.delegate = self
        sourceIn.identifier = NSUserInterfaceItemIdentifier("visual.sourceIn")
        sourceIn.stringValue = "0"
        sourceIn.widthAnchor.constraint(equalToConstant: InspectorSection.numberWidth).isActive = true
        sourceRow.spacing = InspectorSection.spacing
        sourceRow.addArrangedSubview(InspectorSection.label("素材開始")); sourceRow.addArrangedSubview(sourceIn)
        sourceRow.addArrangedSubview(NSTextField(labelWithString: "秒"))
        sourceIn.bindNumber(step: 0.01, current: { [weak self] in self?.track.clip(self?.selectedID)?.content.sourceIn }, initial: { 0 }, normalize: { max(0, $0) }, commit: { [weak self] _ in self?.finishTimingEdit() })
        playbackSpeed.contextMenuProvider = { [weak self] in self?.makePlaybackSpeedMenu() ?? NSMenu() }
        playbackSpeed.delegate = self
        playbackSpeed.identifier = NSUserInterfaceItemIdentifier("visual.playbackSpeed")
        playbackSpeed.stringValue = "1"
        playbackSpeed.knobRange = VisualClip.playbackSpeedRange
        playbackSpeed.knobInitialValue = 1
        playbackSpeed.widthAnchor.constraint(equalToConstant: InspectorSection.numberWidth).isActive = true
        speedRow.spacing = InspectorSection.spacing
        speedRow.addArrangedSubview(InspectorSection.label("再生速度"))
        speedRow.addArrangedSubview(playbackSpeed)
        speedRow.addArrangedSubview(NSTextField(labelWithString: "倍"))
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
        for field in [start, end] { field.widthAnchor.constraint(equalToConstant: InspectorSection.numberWidth).isActive = true }

        keySnap.state = .on
        keySnap.identifier = NSUserInterfaceItemIdentifier("visuals.keySnap")
        keySnap.target = self; keySnap.action = #selector(changeKeySnap)
        keySnap.toolTip = "制御点をタイムラインで選んだ音符の位置またはクリップの端に揃えます"
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
        inspectionHeader.orientation = .vertical
        inspectionHeader.alignment = .leading
        inspectionHeader.spacing = 4
        inspectionHeader.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        name.font = .boldSystemFont(ofSize: 12)
        clipKind.font = .systemFont(ofSize: 11)
        clipKind.textColor = .secondaryLabelColor
        for label in [name, clipKind] {
            inspectionHeader.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: inspectionHeader.widthAnchor, constant: -24).isActive = true
        }
        name.identifier = NSUserInterfaceItemIdentifier("clip.header.name")
        clipKind.identifier = NSUserInterfaceItemIdentifier("clip.header.kind")
        filterControl.identifier = NSUserInterfaceItemIdentifier("clip.filter.mode")
        filterControl.state = modifiedOnly ? .on : .off
        filterControl.target = self; filterControl.action = #selector(changeFilter)
        filterControl.toolTip = "初期値との差、キー・LFO・音楽同期の設定がある項目を表示します"
        filterPicker.identifier = NSUserInterfaceItemIdentifier("clip.filter.pick")
        filterNotice.identifier = NSUserInterfaceItemIdentifier("clip.filter.notice")
        filterNotice.font = .systemFont(ofSize: 11)
        filterNotice.textColor = .secondaryLabelColor
        showAll.target = self; showAll.action = #selector(showAllParameters)
        filterPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filterPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        filterBar.spacing = InspectorSection.spacing
        filterBar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        for child in [NSTextField(labelWithString: "表示"), filterControl, filterPicker] { filterBar.addArrangedSubview(child) }
        sourceIn.onSelect = { [weak self] in self?.revealSourceSettings = true }
        playbackSpeed.onSelect = { [weak self] in self?.revealSourceSettings = true }
        let timing = row([InspectorSection.label("開始"), start, InspectorSection.label("終了", width: 40), end])
        let effect = row([keySnap])
        let horizontal = row([parameterControls(.x), parameterControls(.y)])
        let vertical = row([parameterControls(.scale), parameterControls(.rotation)])
        let opacity = row([parameterControls(.opacity)])
        transformRows = [horizontal, vertical, opacity]
        let graphs = graphSettings
        graphs.spacing = 6
        for child in [NSTextField(labelWithString: "表示範囲"), NSTextField(labelWithString: "最小"), minimum, NSTextField(labelWithString: "最大"), maximum] { graphs.addArrangedSubview(child) }
        graphs.toolTip = "グラフの表示範囲を指定し、Returnで確定します"
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor; message.lineBreakMode = .byTruncatingTail
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        transformSection = InspectorSection("基本変形", id: "visual.transform", rows: [horizontal, vertical, opacity])
        effectsSection = InspectorSection(nil, id: "visual.effects", rows: [effectsEditor])
        targetPicker.identifier = NSUserInterfaceItemIdentifier("clip.target.change")
        targetPath.identifier = NSUserInterfaceItemIdentifier("clip.target.path")
        targetPath.font = .boldSystemFont(ofSize: 12)
        targetStatus.font = .systemFont(ofSize: 11); targetStatus.textColor = .secondaryLabelColor
        targetSummary.font = .systemFont(ofSize: 11); targetSummary.textColor = .secondaryLabelColor
        automationSection = InspectorSection("選択項目の自動化", id: "visual.automation", rows: [targetPath, row([targetPicker]), targetSummary, targetStatus, lfoEditor, musicEditor, effect, graphs])
        placementDetails = [timing, sourceRow, speedRow, spineRow, spineBlendRow]
        let sections: [NSView] = [filterNotice, showAll,
            InspectorSection("素材と配置", id: "visual.source", rows: placementDetails, headingAccessory: placementMenu),
            transformSection, effectsSection, automationSection, message, effectsEditor.belowMaskSection
        ]
        for child in sections { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        effectsEditor.onBelowMaskGuideChange = { [weak self] in self?.onBelowMaskGuideChange?($0) }
        effectsEditor.onSelectNode = { [weak self] id in self?.selectInspectionNode(id) }
        effectsEditor.onSelectParameter = { [weak self] parameter in self?.selectInspectionParameter(parameter) }
        effectsEditor.onSelectEmitter = { [weak self] index in
            guard let self else { return }
            let axis = self.inspectionParameter?.rawValue.hasPrefix("emitter") == true ? String(self.inspectionParameter!.rawValue.suffix(1)) : "X"
            if let parameter = ImageParameter(rawValue: "emitter\(index)" + axis) { self.selectInspectionParameter(parameter) }
        }
        lfoEditor.onCommit = { [weak self] parameter, mode, lfo in self?.setLFO(parameter, mode: mode, lfo: lfo, preview: false) }
        lfoEditor.onPreview = { [weak self] parameter, lfo in
            guard let self else { return }
            if let lfo { self.setLFO(parameter, mode: .lfo, lfo: lfo, preview: true) }
            else { self.timeline?.automationPreview = nil; self.onPreview?(self.track) }
        }
        lfoEditor.onSelect = { [weak self] parameter in self?.selectInspectionParameter(parameter) }
        musicEditor.onCommit = { [weak self] parameter, modulation in self?.setMusic(parameter, modulation: modulation, preview: false) }
        musicEditor.onPreview = { [weak self] parameter, modulation in
            guard let self else { return }
            if let modulation { self.setMusic(parameter, modulation: modulation, preview: true) }
            else { self.timeline?.automationPreview = nil; self.onPreview?(self.track) }
        }
        musicEditor.onSelect = { [weak self] parameter in self?.selectInspectionParameter(parameter) }
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
        clipControls += [start, end, sourceIn, playbackSpeed, spineAnimation, spineLoop, spineAutomation, spineMaximum, spineWeight, minimum, maximum]
        controls = [placementMenu, keySnap] + clipControls
        refreshControls()
    }
    private func row(_ views: [NSView]) -> NSStackView { InspectorSection.row(views) }
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
            guard let self, !self.synchronizingInspection else { return }
            if let parameter = self.timeline?.selectedParameter {
                self.selectInspectionParameter(parameter, fromTimeline: true)
            } else { self.refreshGraphControls() }
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
        let selection = selectedID, layerID = selectedLayerID
        let inspection = (inspectionClipID, inspectionNodeID, inspectionParameter, rememberedParameters)
        let filterSelection = revealedParameter
        let parameter = timeline?.selectedParameter
        let key = timeline?.selectedKeyID
        replaceTrack(value, projectURL: projectURL)
        selectedID = value.clip(selection)?.id; selectedLayerID = selectedID.flatMap { value.layerID(of: $0) } ?? (value.layer(layerID) != nil ? layerID : value.layers[0].id)
        inspectionClipID = inspection.0; inspectionNodeID = inspection.1
        inspectionParameter = inspection.2; rememberedParameters = inspection.3
        revealedParameter = selectedID == selection ? filterSelection : nil
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
        let canEditPlacement = available && !processing && manager == nil && track.canEdit(selectedLayerID)
        for item in placementMenu.itemArray.dropFirst() {
            item.isEnabled = canEditPlacement && (item.action == #selector(addImage) || track.clip(selectedID) != nil)
        }
        clipControls.forEach { $0.isEnabled = available && !processing && manager == nil && track.clip(selectedID) != nil && track.canEdit(selectedLayerID) }
        timeline?.isEnabled = available && !processing && manager == nil
        syncParticleThumbnails()
        effectsEditor.load(track.clip(selectedID), editable: available && !processing && manager == nil && track.canEdit(selectedLayerID), track: track)
        refreshInspection()
    }
    var onColorSession: ((UUID?) -> Void)? {
        didSet { effectsEditor.onColorSession = onColorSession }
    }

    private func applyEffects(_ effects: ImageEffects, preview: Bool, deletedEmitter: Int? = nil) {
        guard available, !processing, manager == nil, var clip = track.clip(selectedID),
              let layerID = track.layerID(of: clip.id) else { return }
        if let deletedEmitter {
            clip.removeEmitterAutomation(at: deletedEmitter)
            remapInspectionEmitter(deletedEmitter)
        }
        let original = clip
        var incoming = effects
        for node in clip.effects?.allNodes ?? [] {
            incoming.editNode(node.id) {
                $0.automations = node.automations; $0.audioModulations = node.audioModulations; $0.automationRanges = node.automationRanges
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
                refreshInspection()
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
        timeline?.selectedImageID = selectedID; timeline?.selectedLayerID = selectedLayerID
        if let clip = track.clip(selectedID) {
            name.stringValue = "\(track.layer(selectedLayerID)?.name ?? "レイヤー") / \(track.asset(clip.assetID)?.name ?? "演出用クリップ")"
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
        } else { name.stringValue = "画像・動画・Spine・演出用クリップを選択してください" }
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
        applyTimingEdit()
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
            applyTimingEdit()
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
        applyTimingEdit()
        refreshSelection()
        onEndTextEditing?()
    }

    @discardableResult
    func cancelValueDrag() -> Bool {
        let lfoCancelled = lfoEditor.cancelDrag()
        let musicCancelled = musicEditor.cancelDrag() || lfoCancelled
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

    private func applyTimingEdit() {
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
            let value = try track.updating(clip, layerID: selectedLayerID, duration: duration)
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
            timeline?.missingAssets = missing; manager?.reload(); updateInspectionStatus()
            syncParticleThumbnails()
            effectsEditor.load(track.clip(selectedID), editable: available && !processing && manager == nil && track.canEdit(selectedLayerID), track: track)
        }
    }
    @objc func openManager() {
        guard available, !processing, manager == nil, finishEditing(), let window = timeline?.window ?? view.window else { return }
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
        field.onSelect = { [weak self] in self?.selectInspectionParameter(parameter) }
        let label = PreviewHandleLabel(parameter.title, field: field)
        label.widthAnchor.constraint(equalToConstant: InspectorSection.labelWidth).isActive = true
        field.stringValue = String(parameter.defaultValue)
        field.knobInitialValue = parameter.defaultValue
        field.knobRange = parameter.valueRange
        connectValueField(field) { .base(parameter) }
        field.identifier = NSUserInterfaceItemIdentifier("visuals.value." + parameter.rawValue)
        field.delegate = self; field.target = self; field.action = #selector(confirmBaseValue(_:))
        field.toolTip = (parameter == .opacity ? "クリップ出力全体の不透明度。" : "固定値・基準値。") + DragValueField.numberEditingHint
        field.widthAnchor.constraint(equalToConstant: InspectorSection.numberWidth).isActive = true
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
        parameterGroups[parameter] = group
        return group
    }
    private func editMusic(_ parameter: ImageParameter) {
        guard available, !processing, manager == nil, let clip = track.clip(selectedID), inspectionParameters(in: clip).contains(parameter) else { return }
        if clip.audioModulations[parameter] == nil { setMusic(parameter, modulation: .initial(for: parameter), preview: false) }
        selectInspectionParameter(parameter)
        view.window?.makeFirstResponder(nil)
        musicEditor.scrollToVisible(musicEditor.bounds)
    }

    private func setLFO(_ parameter: ImageParameter, mode: ParameterAutomation.Mode, lfo: LFOSettings?, preview: Bool) {
        guard available, !processing, manager == nil, track.canEdit(selectedLayerID), var clip = track.clip(selectedID), inspectionParameters(in: clip).contains(parameter) else { return }
        if mode == .keys && clip.automation(parameter) == nil { return }
        clip.setAutomationMode(mode, for: parameter)
        if let lfo { var item = clip.automation(parameter)!; item.lfo = lfo; clip.setAutomation(item) }
        do {
            let updated = try track.updating(clip, layerID: selectedLayerID, duration: duration)
            if preview { timeline?.automationPreview = updated; onPreview?(updated) }
            else if updated != track {
                onBeginEdit?(); commit(updated, selectedID: clip.id)
                timeline?.revealAutomation(in: selectedLayerID); timeline?.selectGraph(parameter, reveal: true)
            }
        } catch { report(error) }
    }

    private func setMusic(_ parameter: ImageParameter, modulation: AudioModulation?, preview: Bool) {
        guard available, !processing, manager == nil, var clip = track.clip(selectedID), let layerID = track.layerID(of: clip.id), inspectionParameters(in: clip).contains(parameter) else { return }
        clip.audioModulations[parameter] = modulation
        if modulation == nil && !clip.hasAutomation(parameter) { clip.automationRanges[parameter] = nil }
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
            field.hasAutomation = clip?.hasAutomation(parameter) == true
            field.hasMusic = clip?.audioModulations[parameter] != nil
            let title = field.hasAutomation ? "基準値" : "固定値"
            field.setAccessibilityLabel(parameter.title + "の" + title)
            field.toolTip = (parameter == .opacity ? "クリップ出力全体の不透明度。" : "") + title + "。\(DragValueField.numberEditingHint)。ノブまたは数値を右クリックでオートメーションを作成・削除"
            guard field.currentEditor() == nil, drafts[parameter] == nil else { continue }
            let value = clip?.baseValue(parameter) ?? parameter.defaultValue
            let text = String(value)
            if field.stringValue != text { field.stringValue = text }
        }
    }

    private func refreshGraphControls(resetRange: Bool = false) {
        let clip = (handlePreview ?? valueDrag?.preview ?? track).clip(selectedID)
        let active = inspectionParameter
        let curve = active.flatMap { clip?.displayCurve($0) }
        graphSettings.isHidden = curve == nil
        let enabled = available && !processing && manager == nil && track.canEdit(selectedLayerID) && clip != nil
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
        guard var clip = track.clip(selectedID), clip.hasAutomation(parameter) else { return }
        if let curve = clip.curve(parameter), clip.audioModulations[parameter] != nil { clip.automationRanges[parameter] = VisualClip.DisplayRange(lower: curve.minimum, upper: curve.maximum) }
        clip.removeAutomation(parameter)
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

private extension VisualEditor {
    func inspectionParameters(in clip: VisualClip) -> [ImageParameter] {
        ImageParameter.allCases.filter { parameter in
            parameter.effectKind == nil || parameter.effect?.read(clip.effects ?? ImageEffects()) != nil
        }
    }

    func inspectionPath(_ parameter: ImageParameter, in clip: VisualClip) -> String {
        let owner = clip.effects?.node(for: parameter)?.kind.title ?? "基本変形"
        var title = parameter.title
        if title.hasPrefix(owner + " ") { title = String(title.dropFirst(owner.count + 1)) }
        if parameter.rawValue.hasPrefix("emitter"), let index = Int(parameter.rawValue.dropFirst(7).prefix(1)) {
            title = "発生源\(index + 1) › " + parameter.rawValue.suffix(1)
        }
        return owner + " › " + title
    }

    func refreshInspection() {
        let clip = track.clip(selectedID)
        if inspectionClipID != clip?.id {
            inspectionClipID = clip?.id
            inspectionNodeID = nil
            inspectionParameter = .scale
            rememberedParameters.removeAll()
            revealedParameter = nil
            revealSourceSettings = false
        }
        let parameters = clip.map(inspectionParameters) ?? []
        let nodes = clip?.effects?.allNodes ?? []
        rememberedParameters = rememberedParameters.filter { id, parameter in
            nodes.contains { $0.id == id } && parameters.contains(parameter)
        }
        if let id = inspectionNodeID, !nodes.contains(where: { $0.id == id }) {
            inspectionNodeID = nil; inspectionParameter = .scale
        }
        if let parameter = inspectionParameter, !parameters.contains(parameter) { inspectionParameter = nil }
        if let parameter = revealedParameter, !parameters.contains(parameter) { revealedParameter = nil }
        for row in placementDetails { row.isHidden = clip == nil }
        sourceRow.isHidden = clip?.content.sourceIn == nil
        speedRow.isHidden = clip?.content.isVideo != true
        spineRow.isHidden = clip?.content.spinePlayback == nil
        if case .blend = clip?.content.spinePlayback?.mode { spineBlendRow.isHidden = false }
        else { spineBlendRow.isHidden = true }
        transformSection.isHidden = clip == nil
        effectsSection.isHidden = clip == nil
        effectsEditor.belowMaskSection.isHidden = clip == nil
        automationSection.isHidden = clip == nil
        targetPicker.isEnabled = clip != nil
        rebuildInspectionMenu(clip, parameters: parameters)
        let editable = available && !processing && manager == nil && track.canEdit(selectedLayerID)
        if let parameter = inspectionParameter, let clip {
            targetPath.stringValue = "対象：" + inspectionPath(parameter, in: clip)
            lfoEditor.select(parameter, notify: false)
            musicEditor.select(parameter, notify: false)
            lfoEditor.load(clip, editable: editable)
            musicEditor.load(clip, editable: editable)
            targetSummary.stringValue = String(format: "基準値：%.4g %@　キー：%d個", clip.baseValue(parameter), parameter.unit, clip.curve(parameter)?.keys.count ?? 0)
            targetSummary.isHidden = false
            keySnap.isHidden = clip.activeLFO(parameter) != nil
        } else {
            let hasParameters = parameters.contains { clip?.effects?.node(for: $0)?.id == inspectionNodeID }
            targetPath.stringValue = hasParameters ? "この演出の項目を選択してください" : "この演出に自動化できる数値項目はありません"
            lfoEditor.cancelDrag(); musicEditor.cancelDrag()
            lfoEditor.load(nil, editable: false); musicEditor.load(nil, editable: false)
            lfoEditor.isHidden = true; musicEditor.isHidden = true
            targetSummary.isHidden = true; keySnap.isHidden = true
        }
        refreshGraphControls()
        updateInspectionStatus()
        synchronizeInspectionGraph()
        refreshFilter()
    }

    func rebuildInspectionMenu(_ clip: VisualClip?, parameters: [ImageParameter]) {
        let menu = NSMenu()
        menu.addItem(withTitle: "対象を変更…", action: nil, keyEquivalent: "")
        guard let clip else { targetPicker.menu = menu; return }
        let groups: [(String, UUID?)] = [("基本変形", nil)] + (clip.effects?.allNodes ?? []).map { ($0.kind.title, Optional($0.id)) }
        for (title, id) in groups {
            let items = parameters.filter { clip.effects?.node(for: $0)?.id == id }
            guard !items.isEmpty else { continue }
            menu.addItem(.separator())
            let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            heading.isEnabled = false; menu.addItem(heading)
            for parameter in items {
                let item = NSMenuItem(title: inspectionPath(parameter, in: clip), action: #selector(changeInspectionTarget(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = parameter.rawValue
                item.state = inspectionParameter == parameter ? .on : .off
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }
        targetPicker.menu = menu
    }

    @objc func changeInspectionTarget(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let parameter = ImageParameter(rawValue: raw),
              view.window?.makeFirstResponder(nil) != false else { return }
        selectInspectionParameter(parameter)
        if let group = parameterGroups[parameter] {
            view.window?.contentView?.layoutSubtreeIfNeeded()
            group.scrollToVisible(group.bounds)
        }
    }

    func selectInspectionNode(_ id: UUID) {
        guard let clip = track.clip(selectedID), clip.effects?.allNodes.contains(where: { $0.id == id }) == true else { return }
        revealedParameter = nil
        inspectionNodeID = id
        inspectionParameter = rememberedParameters[id]
        synchronizeInspectionGraph()
        refreshInspection()
    }

    func updateInspectionStatus() {
        guard isViewLoaded else { return }
        let clip = track.clip(selectedID)
        var description: [String] = []
        if let clip {
            let asset = track.asset(clip.assetID)
            description.append(asset.map { $0.kind.title + "クリップ" } ?? "演出用クリップ")
            if clip.assetID.map({ missing.contains($0) }) == true { description.append("素材が見つかりません") }
            if track.layer(selectedLayerID)?.isLocked == true { description.append("ロック中") }
            name.toolTip = name.stringValue
            var status: [String] = []
            if currentTime < clip.start || currentTime >= clip.end { status.append("クリップ区間外") }
            if clip.effects?.isBypassed == true, inspectionNodeID != nil { status.append("演出チェーンはバイパス中") }
            if let id = inspectionNodeID, let node = clip.effects?.allNodes.first(where: { $0.id == id }), !node.isEnabled { status.append("この演出はOFFです") }
            if let parameter = inspectionParameter, clip.audioModulations[parameter]?.enabled == false { status.append("音楽同期はOFFです") }
            let text = status.joined(separator: " / ")
            if targetStatus.stringValue != text { targetStatus.stringValue = text }
        } else {
            description.append("画像・動画・Spine・演出用クリップ")
            if !targetStatus.stringValue.isEmpty { targetStatus.stringValue = "" }
        }
        let text = description.joined(separator: " / ")
        if clipKind.stringValue != text { clipKind.stringValue = text }
        if targetStatus.isHidden != targetStatus.stringValue.isEmpty { targetStatus.isHidden = targetStatus.stringValue.isEmpty }
    }

    func synchronizeInspectionGraph() {
        guard !synchronizingInspection else { return }
        let parameter = inspectionParameter.flatMap { track.clip(selectedID)?.displayCurve($0) != nil ? $0 : nil }
        guard timeline?.selectedParameter != parameter else { return }
        synchronizingInspection = true
        timeline?.selectGraph(parameter)
        synchronizingInspection = false
    }

    func remapInspectionEmitter(_ deleted: Int) {
        func remap(_ parameter: ImageParameter) -> ImageParameter? {
            let raw = parameter.rawValue
            guard raw.hasPrefix("emitter"), let index = Int(raw.dropFirst(7).prefix(1)) else { return parameter }
            if index == deleted { return nil }
            if index > deleted { return ImageParameter(rawValue: "emitter\(index - 1)" + raw.suffix(1)) }
            return parameter
        }
        inspectionParameter = inspectionParameter.flatMap(remap)
        rememberedParameters = rememberedParameters.compactMapValues(remap)
    }
}

extension VisualEditor {
    /// 数値項目の選択は値・キー・再生位置を変更しない。
    func selectInspectionParameter(_ parameter: ImageParameter, fromTimeline: Bool = false) {
        guard !synchronizingInspection, let clip = track.clip(selectedID), inspectionParameters(in: clip).contains(parameter) else { return }
        let node = clip.effects?.node(for: parameter)
        let changed = inspectionParameter != parameter || inspectionNodeID != node?.id
        revealedParameter = parameter
        revealSourceSettings = false
        inspectionParameter = parameter
        inspectionNodeID = node?.id
        if let node { rememberedParameters[node.id] = parameter }
        if let node, changed { effectsEditor.selectNode(node.id, parameter: parameter) }
        if !fromTimeline { synchronizeInspectionGraph() }
        if changed { refreshInspection() }
        else { refreshGraphControls(); refreshFilter() }
        if fromTimeline, !automationSection.visibleRect.contains(automationSection.bounds) {
            automationSection.scrollToVisible(automationSection.bounds)
        }
    }
}

private extension VisualEditor {
    @objc func changeFilter() {
        guard finishEditing() else { filterControl.state = modifiedOnly ? .on : .off; return }
        modifiedOnly = filterControl.state == .on
        UserDefaults.standard.set(modifiedOnly, forKey: InspectorFilter.defaultsKey)
        revealedParameter = nil
        revealSourceSettings = false
        effectsEditor.clearFilterReveal()
        refreshInspection()
    }

    @objc func showAllParameters() {
        filterControl.state = .off
        changeFilter()
    }

    @objc func revealSource() {
        guard finishEditing() else { return }
        revealSourceSettings = true
        refreshInspection()
        sourceRow.scrollToVisible(sourceRow.bounds)
    }

    @objc func revealEffect(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, finishEditing() else { return }
        selectInspectionNode(id)
        effectsEditor.revealFilterNode(id)
        let section = track.clip(selectedID)?.effects?.allNodes.first(where: { $0.id == id })?.kind == .belowMask
            ? effectsEditor.belowMaskSection : effectsSection!
        section.scrollToVisible(section.bounds)
    }

    func refreshPlaybackFilter(_ clip: VisualClip?) -> Bool {
        guard let clip else { return false }
        let sourceChanged = InspectorFilter.differs(clip.content.sourceIn ?? 0, from: 0)
        let speedChanged = InspectorFilter.differs(clip.content.speed, from: 1)
        let editing = revealSourceSettings || sourceIn.isNumberInteractionActive || playbackSpeed.isNumberInteractionActive
        sourceRow.isHidden = clip.content.sourceIn == nil || (modifiedOnly && !editing && !sourceChanged)
        speedRow.isHidden = !clip.content.isVideo || (modifiedOnly && !editing && !speedChanged)
        var spineChanged = false
        if let playback = clip.content.spinePlayback {
            let initialName = track.asset(clip.assetID)?.kind.spineDescriptor?.animations.first?.name
            let animationChanged = playback.hasLane || playback.animationName != initialName
            spineChanged = animationChanged || !playback.loop
            spineRow.isHidden = modifiedOnly && !editing && !spineChanged
            spineAnimation.isHidden = modifiedOnly && !editing && !animationChanged
            spineLabel.isHidden = spineAnimation.isHidden
            spineLoop.isHidden = modifiedOnly && !editing && playback.loop
        }
        return sourceChanged || speedChanged || spineChanged
    }

    func refreshFilter() {
        guard valueDrag == nil, !valueFields.values.contains(where: { $0.isNumberInteractionActive }) else { return }
        let clip = track.clip(selectedID)
        filterPicker.menu = targetPicker.menu?.copy() as? NSMenu
        filterPicker.menu?.items.first?.title = "項目を選んで編集…"
        if let clip, let menu = filterPicker.menu {
            menu.addItem(.separator())
            if clip.content.sourceIn != nil {
                let item = menu.addItem(withTitle: "素材・再生設定を編集…", action: #selector(revealSource), keyEquivalent: "")
                item.target = self
            }
            for node in clip.effects?.allNodes ?? [] {
                let item = menu.addItem(withTitle: node.kind.title + "の全項目を編集…", action: #selector(revealEffect(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = node.id
            }
        }
        filterPicker.isEnabled = clip != nil
        let changed = clip.map { clip in inspectionParameters(in: clip).filter { InspectorFilter.isModified($0, in: clip) } } ?? []
        let visible = Set(changed + [revealedParameter].compactMap { $0 })
        for (parameter, group) in parameterGroups {
            group.isHidden = modifiedOnly && !visible.contains(parameter)
        }
        for row in transformRows { row.isHidden = row.arrangedSubviews.allSatisfy(\.isHidden) }
        transformSection.isHidden = clip == nil || (modifiedOnly && transformRows.allSatisfy(\.isHidden))
        let changedPlayback = refreshPlaybackFilter(clip)
        let hasChanges = !changed.isEmpty || effectsEditor.hasModifiedProperties || changedPlayback
        let editing = modifiedOnly && revealedParameter.map { !changed.contains($0) } == true
        filterNotice.stringValue = editing ? "編集中：" + (revealedParameter.map { $0.title } ?? "") : "変更したパラメータはありません"
        filterNotice.isHidden = !modifiedOnly || clip == nil || (!editing && hasChanges)
        showAll.isHidden = !modifiedOnly || clip == nil || hasChanges
        automationSection.isHidden = clip == nil || (modifiedOnly && !(inspectionParameter.map { visible.contains($0) } ?? false))
        effectsEditor.setFilter(modifiedOnly: modifiedOnly, parameter: revealedParameter)
    }
}
