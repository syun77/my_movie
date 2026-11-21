import AppKit

@MainActor
final class ImageEffectsEditor: NSStackView, NSTextFieldDelegate {
    var particleThumbnails: [UUID: NSImage] = [:]
    var missingParticleImages = Set<UUID>()
    var onImportParticle: ((UUID, URL) -> Void)?
    private var particleEditors: [EffectKind: ParticleAppearanceEditor] = [:]
    var onSelectEmitter: ((Int) -> Void)?
    var onSelectNode: ((UUID) -> Void)?
    var onSelectParameter: ((ImageParameter) -> Void)?
    var handleTarget: ((ImageParameter) -> PreviewHandleTarget?)?
    var onDeleteEmitter: ((ImageEffects, Int) -> Void)?
    var onCreateAutomation: ((ImageParameter) -> Void)?
    var onEditMusic: ((ImageParameter) -> Void)?
    var onRemoveMusic: ((ImageParameter) -> Void)?
    var onRemoveAutomation: ((ImageParameter) -> Void)?
    var onColorSession: ((UUID?) -> Void)?
    var onCommit: ((ImageEffects) -> Void)?
    var onPreview: ((ImageEffects?) -> Void)?
    private typealias Kind = EffectKind

    private struct NumberInput {
        let field: DragValueField
        let parameter: () -> ImageParameter?
        let read: (ImageEffects) -> Double?
        let write: (ImageEffects, Double) -> ImageEffects
    }

    private let disclosure = NSButton(title: "▸ 追加演出", target: nil, action: nil)
    private let outside = NSTextField(labelWithString: "クリップ区間外")
    private let add = NSPopUpButton(frame: .zero, pullsDown: true)
    private let chainList = EffectChainList()
    private let bypass = NSButton(checkboxWithTitle: "チェーンをバイパス", target: nil, action: nil)
    private let inputLabel = NSTextField(labelWithString: "素材・基本変形 ↓ 上から下へ適用")
    private let outputLabel = NSTextField(labelWithString: "↓ クリップ出力（不透明度・直下段マスク）")
    private let outputMaskButton = NSButton(title: "直下段のマスクを設定", target: nil, action: nil)
    private var detailsOpen = true
    private let enabled = NSButton(checkboxWithTitle: "有効", target: nil, action: nil)
    private let remove = NSButton(title: "削除", target: nil, action: nil)
    private let focusColor = NSColorWell()
    private let raysColor = NSColorWell()
    private let raysShuffle = NSButton(title: "配置を変更", target: nil, action: nil)
    private let raysFit = NSButton(title: "画面比率に合わせる", target: nil, action: nil)
    private let spiralColor = NSColorWell()
    private let spiralDirection = NSPopUpButton()
    private let spiralShuffle = NSButton(title: "配置を変更", target: nil, action: nil)
    private let beamColor = NSColorWell()
    private let beamShuffle = NSButton(title: "配置を変更", target: nil, action: nil)
    private let straightColor = NSColorWell()
    private let straightShuffle = NSButton(title: "配置を変更", target: nil, action: nil)
    private let sharpColor = NSColorWell()
    private let binarizationDarkColor = NSColorWell()
    private let binarizationLightColor = NSColorWell()
    private let binarizationSwap = NSButton(title: "色を入れ替え", target: nil, action: nil)
    private let sobelColor = NSColorWell()
    private let sobelMode = NSPopUpButton()
    private let shapeColor = NSColorWell()
    private let shapeKind = NSPopUpButton()
    private let maskKind = NSPopUpButton()
    private let flareAutomatic = NSButton(checkboxWithTitle: "自動移動", target: nil, action: nil)
    private let maskInverted = NSButton(checkboxWithTitle: "反転", target: nil, action: nil)
    private let belowTarget = NSTextField(wrappingLabelWithString: "")
    private let maskStatus = NSTextField(wrappingLabelWithString: "")
    private let backgroundNotice = NSButton(checkboxWithTitle: "単色背景が有効", target: nil, action: nil)
    private let copyShape = NSButton(title: "図形をマスクへコピー", target: nil, action: nil)
    private var shapeStarRows: [NSView] = []
    private var maskStarRows: [NSView] = []
    private var track = VisualTrack()
    private let color = NSColorWell()
    private let backgroundColor = NSColorWell()
    private let gradientColorA = SessionColorWell()
    private let gradientColorB = SessionColorWell()
    private let gradientShape = NSPopUpButton()
    private let gradientPattern = NSPopUpButton()
    private let gradientSwap = NSButton(title: "A/B交換", target: nil, action: nil)
    private let gradientOutward = NSButton(title: "中心から外へ", target: nil, action: nil)
    private let gradientProfile = GradientProfileView()
    private let gradientNotice = NSTextField(wrappingLabelWithString: "前段の不透明な背景に隠れる場合があります。")
    private var gradientAngleRow: NSView?
    private let emitterPicker = NSPopUpButton()
    private let addEmitter = NSButton(title: "＋", target: nil, action: nil)
    private let removeEmitter = NSButton(title: "−", target: nil, action: nil)
    private var selectedEmitter = 0
    private var contents: [Kind: NSStackView] = [:]
    private var numbers: [NumberInput] = []
    private var selected: Kind?
    private var shownClip: VisualClip?
    private var effects = ImageEffects()
    private var editable = false
    private var expanded = false
    private lazy var toolbar = row([enabled, remove, add])
    var time = 0.0 { didSet { updateOutside(); updateMaskStatus() } }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        disclosure.target = self; disclosure.action = #selector(toggleDisclosure)
        disclosure.identifier = NSUserInterfaceItemIdentifier("visuals.effects")
        outside.textColor = .secondaryLabelColor
        outside.font = .systemFont(ofSize: 11)
        add.identifier = NSUserInterfaceItemIdentifier("visuals.effects.add")
        add.setAccessibilityLabel("演出をカテゴリから追加")
        enabled.target = self; enabled.action = #selector(toggleEffect)
        remove.target = self; remove.action = #selector(removeEffect)
        for (well, action, label) in [(color, #selector(changeColor), "光の粒子の色"),
                                      (backgroundColor, #selector(changeBackgroundColor), "単色背景の色"),
                                      (gradientColorA, #selector(changeGradientColors(_:)), "グラデーションの色A"),
                                      (gradientColorB, #selector(changeGradientColors(_:)), "グラデーションの色B"),
                                      (binarizationDarkColor, #selector(changeBinarizationColor(_:)), "2値化の暗部の色"),
                                      (binarizationLightColor, #selector(changeBinarizationColor(_:)), "2値化の明部の色"),
                                      (sobelColor, #selector(changeSobelColor), "Sobelの輪郭色"),
                                      (shapeColor, #selector(changeShapeColor), "図形の色"),
                                      (sharpColor, #selector(changeSharpColor), "集中線３の色"),
                                      (spiralColor, #selector(changeSpiralColor), "渦巻き粒子の色"),
                                      (beamColor, #selector(changeBeamColor), "電撃ビームの色"),
                                      (straightColor, #selector(changeStraightColor), "直線効果線の色"),
                                      (raysColor, #selector(changeRaysColor), "放射光線の色"),
                                      (focusColor, #selector(changeFocusColor), "集中線の色")] {
            well.target = self; well.action = action
            well.colorWellStyle = .minimal
            well.isContinuous = true
            well.setAccessibilityLabel(label)
            well.widthAnchor.constraint(equalToConstant: 32).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        backgroundColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.backgroundColor")
        contents[.solidBackground] = row([NSTextField(labelWithString: "色"), backgroundColor])

        buildGradientControls()

        emitterPicker.setAccessibilityLabel("光の粒子の発生源")
        emitterPicker.target = self; emitterPicker.action = #selector(selectEmitter)
        addEmitter.setAccessibilityLabel("発生源を追加")
        addEmitter.target = self; addEmitter.action = #selector(insertEmitter)
        removeEmitter.setAccessibilityLabel("発生源を削除")
        removeEmitter.target = self; removeEmitter.action = #selector(deleteEmitter)

        typealias Chromatic = ImageEffects.ChromaticAberration
        contents[.chromaticAberration] = row(number("ずれ量 px", .chromaticAmount, \.chromaticAberration, \.amount, Chromatic().amount, Chromatic.amountRange)
            + number("角度 °", .chromaticAngle, \.chromaticAberration, \.angle, Chromatic().angle, Chromatic.angleRange))
        sobelColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.sobel.color")
        sobelMode.identifier = NSUserInterfaceItemIdentifier("visuals.effects.sobel.mode")
        sobelMode.addItems(withTitles: ImageEffects.SobelChromatic.Mode.allCases.map(\.title))
        sobelMode.setAccessibilityLabel("Sobelの表示モード")
        sobelMode.target = self; sobelMode.action = #selector(changeSobelMode)
        contents[.sobelChromatic] = NSStackView(views:
            [row([NSTextField(labelWithString: "表示モード"), sobelMode])]
            + ImageEffects.SobelChromatic.parameters.map { row(numeric($0)) }
            + [row([NSTextField(labelWithString: "輪郭色"), sobelColor])])
        contents[.vignette] = row(number("強さ %", .vignetteStrength, \.vignette, \.strength, 70, 0...100)
            + number("範囲 %", .vignetteSize, \.vignette, \.size, 70, 0...100)
            + number("ぼかし %", .vignetteSoftness, \.vignette, \.softness, 60, 0...100))
        binarizationDarkColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.binarization.darkColor")
        binarizationLightColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.binarization.lightColor")
        binarizationSwap.identifier = NSUserInterfaceItemIdentifier("visuals.effects.binarization.swap")
        binarizationSwap.target = self; binarizationSwap.action = #selector(swapBinarizationColors)
        contents[.binarization] = NSStackView(views: [
            row(numeric(.binarizationThreshold) + numeric(.binarizationAmount)),
            row([NSTextField(labelWithString: "暗部"), binarizationDarkColor,
                 NSTextField(labelWithString: "明部"), binarizationLightColor, binarizationSwap])
        ])
        typealias Correction = ImageEffects.ColorCorrection
        contents[.colorCorrection] = row(number("色相 °", .colorHue, \.colorCorrection, \.hue, Correction().hue, Correction.hueRange)
            + number("明度 %", .colorBrightness, \.colorCorrection, \.brightness, Correction().brightness, Correction.brightnessRange)
            + number("彩度 %", .colorSaturation, \.colorCorrection, \.saturation, Correction().saturation, Correction.saturationRange))
        typealias Shake = ImageEffects.Shake
        contents[.shake] = row(number("X強さ px", .shakeX, \.shake, \.x, Shake().x, Shake.amplitudeRange)
            + number("Y強さ px", .shakeY, \.shake, \.y, Shake().y, Shake.amplitudeRange)
            + number("総合強さ %", .shakeStrength, \.shake, \.strength, Shake().strength, Shake.strengthRange))
        typealias Blur = ImageEffects.Blur
        typealias Bloom = ImageEffects.Bloom
        typealias Particles = ImageEffects.Particles
        typealias Embers = ImageEffects.Embers
        contents[.radialBlur] = NSStackView(views: ImageEffects.RadialBlur.parameters.map { row(numeric($0)) })
        contents[.blur] = row(number("半径 px", .blurRadius, \.blur, \.radius, Blur().radius, Blur.radiusRange))
        flareAutomatic.target = self
        flareAutomatic.action = #selector(changeFlareAutomatic)
        flareAutomatic.identifier = NSUserInterfaceItemIdentifier("visuals.flare.automatic")
        contents[.lensFlare] = NSStackView(views: [flareAutomatic] + ImageEffects.LensFlare.parameters.map { row(numeric($0)) })
        contents[.crossGlare] = NSStackView(views: ImageEffects.CrossGlare.parameters.map { row(numeric($0)) })
        contents[.bloom] = row(number("しきい値 %", .bloomThreshold, \.bloom, \.threshold, Bloom().threshold, Bloom.thresholdRange)
            + number("半径 px", .bloomRadius, \.bloom, \.radius, Bloom().radius, Bloom.radiusRange)
            + number("強さ %", .bloomIntensity, \.bloom, \.intensity, Bloom().intensity, Bloom.intensityRange))
        let particleDefaults = Particles(seed: 0)
        contents[.particles] = NSStackView(views: [
            row(number("個数", .particlesCount, \.particles, \.count, particleDefaults.count, Particles.countRange)
                + number("基準直径 px", .particlesDiameter, \.particles, \.diameter, particleDefaults.diameter, Particles.diameterRange)
                + number("基準速度 px/秒", .particlesSpeed, \.particles, \.speed, particleDefaults.speed, Particles.speedRange)),
            row(number("曲線の強さ %", .particlesCurveStrength, \.particles, \.curveStrength, particleDefaults.curveStrength, Particles.curveStrengthRange)
                + number("不透明度 %", .particlesOpacity, \.particles, \.opacity, particleDefaults.opacity, Particles.opacityRange)
                + [NSTextField(labelWithString: "色"), color]),
            row([NSTextField(labelWithString: "発生源"), emitterPicker, addEmitter, removeEmitter]
                + emitterCoordinate("X", \.x, Particles.Emitter.xRange)
                + emitterCoordinate("Y", \.y, Particles.Emitter.yRange))
        ])
        let emberDefaults = Embers(seed: 0)
        contents[.embers] = NSStackView(views: [
            row(number("個数", .embersCount, \.embers, \.count, emberDefaults.count, Embers.countRange)
                + number("大きさ px", .embersDiameter, \.embers, \.diameter, emberDefaults.diameter, Embers.diameterRange)
                + number("上昇速度 px/秒", .embersRiseSpeed, \.embers, \.riseSpeed, emberDefaults.riseSpeed, Embers.riseSpeedRange)),
            row(number("横風 px/秒", .embersWind, \.embers, \.wind, emberDefaults.wind, Embers.windRange)
                + number("揺れの速さ %", .embersSwaySpeed, \.embers, \.swaySpeed, emberDefaults.swaySpeed, Embers.swaySpeedRange)
                + number("明るさ %", .embersBrightness, \.embers, \.brightness, emberDefaults.brightness, Embers.brightnessRange))
        ])
        typealias Snow = ImageEffects.Snow
        let snowDefaults = Snow(seed: 0)
        contents[.snow] = NSStackView(views: [
            row(number("個数", .snowCount, \.snow, \.count, snowDefaults.count, Snow.countRange)
                + number("大きさ px", .snowDiameter, \.snow, \.diameter, snowDefaults.diameter, Snow.diameterRange)
                + number("落下速度 px/秒", .snowFallSpeed, \.snow, \.fallSpeed, snowDefaults.fallSpeed, Snow.fallSpeedRange)),
            row(number("横風 %", .snowWind, \.snow, \.wind, snowDefaults.wind, Snow.windRange)
                + number("不透明度 %", .snowOpacity, \.snow, \.opacity, snowDefaults.opacity, Snow.opacityRange))
        ])
        typealias Orbs = ImageEffects.Orbs
        let orbDefaults = Orbs()
        contents[.orbs] = NSStackView(views: [
            row(number("発生数", .orbsCount, \.orbs, \.count, orbDefaults.count, Orbs.countRange)
                + number("彩度 %", .orbsSaturation, \.orbs, \.saturation, orbDefaults.saturation, Orbs.saturationRange)),
            row(number("速度 %", .orbsSpeed, \.orbs, \.speed, orbDefaults.speed, Orbs.speedRange)
                + number("不透明度 %", .orbsOpacity, \.orbs, \.opacity, orbDefaults.opacity, Orbs.opacityRange))
        ])
        spiralColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.spiralColor")
        spiralDirection.addItems(withTitles: ImageEffects.SpiralParticles.Direction.allCases.map(\.title))
        spiralDirection.identifier = NSUserInterfaceItemIdentifier("visuals.effects.spiralDirection")
        spiralDirection.target = self; spiralDirection.action = #selector(changeSpiralDirection)
        spiralShuffle.identifier = NSUserInterfaceItemIdentifier("visuals.effects.spiralShuffle")
        spiralShuffle.target = self; spiralShuffle.action = #selector(shuffleSpiral)
        contents[.spiralParticles] = NSStackView(views: ImageEffects.SpiralParticles.fields.map { row(numeric($0.parameter)) }
            + [row([NSTextField(labelWithString: "回転方向"), spiralDirection]),
               row([NSTextField(labelWithString: "色"), spiralColor, spiralShuffle])])
        beamColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.beamColor")
        beamShuffle.identifier = NSUserInterfaceItemIdentifier("visuals.effects.beamShuffle")
        beamShuffle.target = self; beamShuffle.action = #selector(shuffleBeam)
        contents[.electricBeam] = NSStackView(views: ImageEffects.ElectricBeam.parameters.map { row(numeric($0)) }
            + [row([NSTextField(labelWithString: "色"), beamColor, beamShuffle]),
               NSTextField(wrappingLabelWithString: "電撃だけを重ねる場合は単色背景をOFFにします。")])
        contents[.fireOutline] = NSStackView(views: ImageEffects.FireOutline.parameters.map { row(numeric($0)) })
        contents[.radialFocus] = NSStackView(views: ImageEffects.RadialFocus.parameters.map { row(numeric($0)) })
        contents[.zoomLoop] = NSStackView(views: ImageEffects.ZoomLoop.parameters.map { row(numeric($0)) })
        contents[.octgrams] = NSStackView(views: ImageEffects.Octgrams.parameters.map { row(numeric($0)) })
        contents[.warpFlight] = NSStackView(views: ImageEffects.WarpFlight.parameters.map { row(numeric($0)) })
        for kind in [Kind.particles, .embers, .snow, .orbs, .spiralParticles] {
            let editor = ParticleAppearanceEditor()
            particleEditors[kind] = editor
            editor.onChange = { [weak self] value in
                guard let self, self.editable else { return }
                var result = self.effects; result.setAppearance(value, for: kind); self.onCommit?(result)
            }
            editor.onImport = { [weak self] url in
                guard let self, let node = self.effects.nodes.first(where: { $0.kind == kind }) else { return }
                self.onImportParticle?(node.id, url)
            }
            contents[kind]?.addArrangedSubview(editor)
            for parameter in ImageParameter.allCases where parameter.effectKind == kind && parameter.rawValue.contains("Image") {
                contents[kind]?.addArrangedSubview(row(numeric(parameter)))
            }
        }
        buildFocusControls()
        buildSharpControls()
        buildStraightControls()
        buildRaysControls()
        buildShapeControls()
        for kind in [Kind.spiralParticles, .gradientBackground, .electricBeam, .fireOutline, .sobelChromatic, .lensFlare, .crossGlare, .warpFlight, .radialFocus, .zoomLoop, .octgrams, .particles, .embers, .snow, .orbs, .focusLines, .sharpFocus, .straightLines, .radialRays, .shape, .mask] {
            contents[kind]?.orientation = .vertical
            contents[kind]?.alignment = .leading
            contents[kind]?.spacing = 4
        }
        addArrangedSubview(row([disclosure, outside]))
        bypass.target = self; bypass.action = #selector(toggleBypass)
        bypass.identifier = NSUserInterfaceItemIdentifier("visuals.effects.bypass")
        outputMaskButton.target = self; outputMaskButton.action = #selector(selectOutputMask)
        chainList.onSelect = { [weak self] id in
            guard let self, let node = self.effects.nodes.first(where: { $0.id == id }), self.window?.makeFirstResponder(nil) != false else { return }
            self.cancelDrag(); self.deactivateColors()
            if self.selected == node.kind { self.detailsOpen.toggle() } else { self.detailsOpen = true }
            self.selected = node.kind; self.updateControls(); self.onSelectNode?(node.id)
        }
        chainList.onToggle = { [weak self] id in
            guard let self else { return }
            var value = self.effects; value.editNode(id) { $0.isEnabled.toggle() }; self.onCommit?(value)
        }
        chainList.onMove = { [weak self] id, index, preview in
            guard let self else { return }
            var value = self.effects; value.move(id, to: index)
            if preview { self.onPreview?(value) } else { self.onCommit?(value) }
        }
        chainList.onCancel = { [weak self] in self?.onPreview?(nil) }
        chainList.menuForNode = { [weak self] id in self?.chainMenu(id) ?? NSMenu() }
        for view in [bypass, inputLabel, chainList, outputLabel, outputMaskButton] {
            addArrangedSubview(view)
        }
        chainList.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        addArrangedSubview(toolbar)
        addArrangedSubview(backgroundNotice)
        for kind in Kind.allCases {
            if let content = contents[kind] { addArrangedSubview(content) }
        }
        updateControls()
    }

    required init?(coder: NSCoder) { nil }

    func updateLayerContext(_ clip: VisualClip?, track: VisualTrack?) {
        let index = clip.flatMap { clip in track?.layers.firstIndex { $0.clips.contains { $0.id == clip.id } } }
        let name = index.flatMap { $0 > 0 ? track?.layers[$0 - 1].name : nil }
        belowTarget.stringValue = "対象: " + (name ?? "なし（直下のレイヤーがありません）")
    }

    func load(_ clip: VisualClip?, editable: Bool, track: VisualTrack? = nil) {
        updateLayerContext(clip, track: track)
        if let track { self.track = track }
        if clip?.id != shownClip?.id || !editable { cancelDrag() }
        if clip?.id != shownClip?.id { selectedEmitter = 0; selected = nil; detailsOpen = true }
        if clip?.id != shownClip?.id || !editable { deactivateColors() }
        shownClip = clip
        effects = clip?.effects ?? ImageEffects()
        self.editable = editable && clip != nil
        updateControls()
    }

    func selectNode(_ id: UUID, parameter: ImageParameter? = nil) {
        guard let node = effects.allNodes.first(where: { $0.id == id }) else { return }
        let needsUpdate = selected != node.kind || !expanded || !detailsOpen
        if selected != node.kind { cancelDrag(); deactivateColors() }
        selected = node.kind
        if let parameter, parameter.rawValue.hasPrefix("emitter"),
           let index = Int(parameter.rawValue.dropFirst(7).prefix(1)) {
            selectedEmitter = index
        }
        expanded = true; detailsOpen = true
        if needsUpdate || parameter?.rawValue.hasPrefix("emitter") == true { updateControls() }
    }

    @discardableResult
    func cancelDrag() -> Bool {
        chainList.cancelDrag() || numbers.contains { $0.field.cancelNumberDrag() }
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.alignment = .centerY
        stack.spacing = InspectorSection.spacing
        return stack
    }

    private func number<T>(_ title: String, _ parameter: ImageParameter, _ effect: WritableKeyPath<ImageEffects, T?>,
                           _ value: WritableKeyPath<T, Double>, _ initial: Double,
                           _ range: ClosedRange<Double>) -> [NSView] {
        number(title, initial: initial, range: range, parameter: { parameter }, read: { $0[keyPath: effect]?[keyPath: value] }) { effects, number in
            var result = effects
            result[keyPath: effect]?[keyPath: value] = number
            return result
        }
    }

    private func emitterCoordinate(_ title: String, _ coordinate: WritableKeyPath<ImageEffects.Particles.Emitter, Double>,
                                   _ range: ClosedRange<Double>) -> [NSView] {
        number(title, initial: ImageEffects.Particles.Emitter()[keyPath: coordinate], range: range,
               accessibilityLabel: "発生源の" + title, parameter: { [weak self] in
            self.flatMap { ImageParameter(rawValue: "emitter\($0.selectedEmitter)" + title) }
        }, read: { [weak self] effects in
            guard let self, let emitters = effects.particles?.emitters, emitters.indices.contains(self.selectedEmitter) else { return nil }
            return emitters[self.selectedEmitter][keyPath: coordinate]
        }) { [weak self] effects, number in
            guard let self, let emitters = effects.particles?.emitters, emitters.indices.contains(self.selectedEmitter) else { return effects }
            var result = effects
            result.particles?.emitters[self.selectedEmitter][keyPath: coordinate] = number
            return result
        }
    }

    private func number(_ title: String, initial: Double, range: ClosedRange<Double>, accessibilityLabel: String? = nil,
                        parameter: @escaping () -> ImageParameter?,
                        read: @escaping (ImageEffects) -> Double?,
                        update: @escaping (ImageEffects, Double) -> ImageEffects) -> [NSView] {
        let field = DragValueField(frame: .zero)
        field.widthAnchor.constraint(equalToConstant: InspectorSection.numberWidth).isActive = true
        field.previewHandleProvider = { [weak self] in
            guard let parameter = parameter() else { return nil }
            return self?.handleTarget?(parameter)
        }
        field.onSelect = { [weak self] in
            if let parameter = parameter() { self?.onSelectParameter?(parameter) }
        }
        field.alignment = .right
        field.knobRange = range
        field.setAccessibilityLabel(accessibilityLabel ?? title)
        field.delegate = self
        let step: Double
        switch parameter() {
        case .raysSquash, .sobelWidth: step = 0.25
        case .spiralConvergenceTime: step = 0.05
        case .spiralTurns, .raysThickness: step = 0.1
        case .straightThickness, .beamWidth: step = 0.5
        default: step = 1
        }
        let write: (ImageEffects, Double) -> ImageEffects = { effects, value in
            let rounded = (value / step).rounded() * step
            return update(effects, min(range.upperBound, max(range.lowerBound, rounded)))
        }
        field.bindNumber(step: step, current: { [weak self] in self.flatMap { read($0.effects) } },
                         initial: { initial }, normalize: { min(range.upperBound, max(range.lowerBound, $0)) },
                         preview: { [weak self] value in
            guard let self else { return }
            let preview = value.map { write(self.effects, $0) }
            if parameter()?.effectKind == .gradientBackground {
                self.gradientProfile.gradient = (preview ?? self.effects).gradientBackground ?? .init()
            }
            self.onPreview?(preview)
        }, commit: { [weak self] value in
            guard let self else { return }
            self.onCommit?(write(self.effects, value))
        })
        if parameter() != nil {
            field.onCreateAutomation = { [weak self] in if let parameter = parameter() { self?.onCreateAutomation?(parameter) } }
            field.onRemoveAutomation = { [weak self] in if let parameter = parameter() { self?.onRemoveAutomation?(parameter) } }
            field.onEditMusic = { [weak self] in if let parameter = parameter() { self?.onEditMusic?(parameter) } }
            field.onRemoveMusic = { [weak self] in if let parameter = parameter() { self?.onRemoveMusic?(parameter) } }
        }
        numbers.append(NumberInput(field: field, parameter: parameter, read: read, write: write))
        let group = NSStackView(views: [PreviewHandleLabel(title, field: field), field])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 2
        return [group]
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let input = numbers.first(where: { $0.field === notification.object as? DragValueField }),
              let original = input.read(effects) else { return }
        let value = Double(input.field.stringValue.trimmingCharacters(in: .whitespaces))
        input.field.doubleValue = original
        if let value, value.isFinite {
            if input.parameter()?.effectKind == .gradientBackground,
               input.field.knobRange?.contains(value) != true { return }
            onCommit?(input.write(effects, value))
        }
    }

    private func updateOutside() {
        let inside = shownClip.map { $0.start <= time && time < $0.end } ?? true
        let hidden = !expanded || inside
        if outside.isHidden != hidden { outside.isHidden = hidden }
    }

    private func updateControls() {
        for (kind, editor) in particleEditors {
            editor.load(effects.appearance(kind) ?? ParticleAppearance(), assets: track.assets,
                        thumbnails: particleThumbnails, missing: missingParticleImages, editable: editable)
        }
        let kinds = effects.allNodes.map(\.kind)
        if selected.map({ !kinds.contains($0) }) ?? true { selected = kinds.first }
        let menu = additionMenu()
        let title = NSMenuItem(title: "＋ 演出を追加", action: nil, keyEquivalent: "")
        title.tag = -1
        menu.insertItem(title, at: 0)
        add.menu = menu
        for kind in Kind.allCases {
            contents[kind]?.isHidden = !expanded || !detailsOpen || selected != kind
        }
        disclosure.isEnabled = editable || expanded
        disclosure.title = expanded ? "▾ 追加演出" : "▸ 追加演出"
        for view in [bypass, inputLabel, chainList, outputLabel, outputMaskButton] { view.isHidden = !expanded }
        bypass.state = effects.isBypassed ? .on : .off; bypass.isEnabled = editable
        outputMaskButton.isEnabled = editable
        chainList.detailsOpen = detailsOpen
        chainList.nodes = effects.nodes
        chainList.editable = editable
        chainList.selectedID = effects.nodes.first { $0.kind == selected }?.id
        toolbar.isHidden = !expanded
        add.isEnabled = editable
        enabled.isEnabled = editable && !kinds.isEmpty
        remove.isEnabled = enabled.isEnabled
        enabled.state = effects.allNodes.first(where: { $0.kind == selected })?.isEnabled == true ? .on : .off
        if let particles = effects.particles, !color.isActive { color.color = particles.color.nsColor }
        color.isEnabled = editable && !(effects.appearance(.particles).map { $0.usesImage && $0.colorMode == .original } ?? false)
        if let focus = effects.focusLines, !focusColor.isActive { focusColor.color = focus.color.nsColor }
        focusColor.isEnabled = editable
        if let sharp = effects.sharpFocus, !sharpColor.isActive { sharpColor.color = sharp.color.nsColor }
        sharpColor.isEnabled = editable
        if let straight = effects.straightLines, !straightColor.isActive { straightColor.color = straight.color.nsColor }
        straightColor.isEnabled = editable
        if let value = effects.spiralParticles {
            if !spiralColor.isActive { spiralColor.color = value.color.nsColor }
            spiralDirection.selectItem(at: ImageEffects.SpiralParticles.Direction.allCases.firstIndex(of: value.direction) ?? 0)
        }
        spiralColor.isEnabled = editable && !(effects.appearance(.spiralParticles).map { $0.usesImage && $0.colorMode == .original } ?? false)
        spiralDirection.isEnabled = editable; spiralShuffle.isEnabled = editable
        if let beam = effects.electricBeam, !beamColor.isActive { beamColor.color = beam.color.nsColor }
        beamColor.isEnabled = editable; beamShuffle.isEnabled = editable
        straightShuffle.isEnabled = editable
        if let rays = effects.radialRays, !raysColor.isActive { raysColor.color = rays.color.nsColor }
        raysColor.isEnabled = editable
        raysShuffle.isEnabled = editable
        raysFit.isEnabled = editable
        if let background = effects.solidBackground, !backgroundColor.isActive { backgroundColor.color = background.color.nsColor }
        backgroundColor.isEnabled = editable
        flareAutomatic.state = effects.lensFlare?.automaticMotion == true ? .on : .off
        flareAutomatic.isEnabled = editable && effects.lensFlare != nil
        if let value = effects.binarization {
            if !binarizationDarkColor.isActive { binarizationDarkColor.color = value.darkColor.nsColor }
            if !binarizationLightColor.isActive { binarizationLightColor.color = value.lightColor.nsColor }
        }
        binarizationDarkColor.isEnabled = editable
        binarizationLightColor.isEnabled = editable
        binarizationSwap.isEnabled = editable && effects.binarization != nil
        if let value = effects.sobelChromatic {
            sobelMode.selectItem(at: ImageEffects.SobelChromatic.Mode.allCases.firstIndex(of: value.mode) ?? 0)
            if !sobelColor.isActive { sobelColor.color = value.edgeColor.nsColor }
        }
        sobelMode.isEnabled = editable && effects.sobelChromatic != nil
        sobelColor.isEnabled = sobelMode.isEnabled && effects.sobelChromatic?.mode != .chromatic
        updateGradientControls()
        updateShapeControls()
        updateEmitterControls()
        for input in numbers {
            let value = input.read(effects)
            let automaticPosition = effects.lensFlare?.automaticMotion == true && input.parameter().map { [ImageParameter.flareX, .flareY].contains($0) } == true
            let appearance = input.parameter()?.effectKind.flatMap { effects.appearance($0) }
            let imageDisabled = input.parameter().map { $0.rawValue.contains("Image") && appearance?.usesImage != true } ?? false
            let saturationDisabled = input.parameter() == .orbsSaturation && appearance?.usesImage == true && appearance?.colorMode == .original
            let sobelDisabled = input.parameter().map { $0.effectKind == .sobelChromatic && effects.sobelChromatic?.uses($0) == false } ?? false
            let spiralGlowDisabled = input.parameter().map { [ImageParameter.spiralGlowWidth, .spiralGlowStrength].contains($0) } == true
                && appearance?.usesImage == true
            let gradientAngleDisabled = input.parameter() == .gradientAngle && effects.gradientBackground?.shape == .radial
            if input.parameter()?.rawValue.contains("Image") == true { input.field.superview?.isHidden = imageDisabled }
            input.field.isEnabled = editable && value != nil && !automaticPosition && !imageDisabled
                && !saturationDisabled && !sobelDisabled && !gradientAngleDisabled && !spiralGlowDisabled
            input.field.identifier = input.parameter().map { NSUserInterfaceItemIdentifier("visuals.value." + $0.rawValue) }
            input.field.hasMusic = input.parameter().flatMap { shownClip?.audioModulations[$0] } != nil
            input.field.hasAutomation = input.parameter().map { shownClip?.hasAutomation($0) == true } == true
            if input.field.currentEditor() == nil, let value { input.field.doubleValue = value }
        }
        updateOutside()
    }

    private func updateEmitterControls() {
        let count = effects.particles?.emitters.count ?? 0
        if emitterPicker.numberOfItems != count {
            emitterPicker.removeAllItems()
            emitterPicker.addItems(withTitles: (0..<count).map { "\($0 + 1)" })
        }
        selectedEmitter = min(selectedEmitter, max(0, count - 1))
        if count > 0 { emitterPicker.selectItem(at: selectedEmitter) }
        emitterPicker.isEnabled = editable && count > 1
        addEmitter.isEnabled = editable && count > 0 && count < ImageEffects.Particles.emitterLimit
        removeEmitter.isEnabled = editable && count > 1
    }

    @objc private func selectEmitter() {
        let index = emitterPicker.indexOfSelectedItem
        guard index >= 0, window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        selectedEmitter = index
        updateControls()
        onSelectEmitter?(index)
    }

    @objc private func insertEmitter() {
        guard addEmitter.isEnabled, window?.makeFirstResponder(nil) != false, var particles = effects.particles else { return }
        cancelDrag()
        particles.addEmitter()
        selectedEmitter = particles.emitters.count - 1
        var result = effects
        result.particles = particles
        onCommit?(result)
    }

    @objc private func deleteEmitter() {
        guard removeEmitter.isEnabled, window?.makeFirstResponder(nil) != false, var particles = effects.particles else { return }
        cancelDrag()
        let deletedIndex = selectedEmitter
        particles.emitters.remove(at: deletedIndex)
        selectedEmitter = min(selectedEmitter, particles.emitters.count - 1)
        var result = effects
        result.particles = particles
        onDeleteEmitter?(result, deletedIndex)
    }

    @objc private func toggleDisclosure() {
        guard window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        expanded.toggle()
        if !expanded { deactivateColors() }
        updateControls()
    }

    private func additionMenu(after anchor: UUID? = nil) -> NSMenu {
        let clipID = shownClip?.id
        return EffectCategory.additionMenu(effects: effects, editable: editable) { [weak self] kind in
            guard let self, self.editable, let clipID, self.shownClip?.id == clipID,
                  !kind.exists(in: self.effects), self.window?.makeFirstResponder(nil) != false else { return }
            self.cancelDrag()
            guard self.editable, self.shownClip?.id == clipID, !kind.exists(in: self.effects) else { return }
            var result = self.effects
            let insertion: Int
            if let anchor {
                guard let index = result.nodes.firstIndex(where: { $0.id == anchor }) else { return }
                insertion = index + 1
            } else {
                insertion = result.nodes.count
            }
            self.deactivateColors()
            result.set(kind, payload: kind.initial)
            if let node = result.nodes.last { result.move(node.id, to: insertion) }
            self.selected = kind
            self.detailsOpen = true
            self.expanded = true
            self.onCommit?(result)
            if let node = result.allNodes.first(where: { $0.kind == kind }) { self.onSelectNode?(node.id) }
        }
    }

    @objc private func toggleEffect() {
        let isEnabled = enabled.state == .on
        guard editable, window?.makeFirstResponder(nil) != false else { return }
        var result = effects
        guard let kind = selected, let node = result.allNodes.first(where: { $0.kind == kind }) else { return }
        result.editNode(node.id) { $0.isEnabled = isEnabled }
        onCommit?(result)
    }

    @objc private func removeEffect() {
        guard editable, window?.makeFirstResponder(nil) != false else { return }
        deactivateColors()
        var result = effects
        guard let selected else { return }
        result.set(selected, payload: nil)
        onCommit?(result)
    }

    private func deactivateColors() {
        binarizationDarkColor.deactivate()
        binarizationLightColor.deactivate()
        sobelColor.deactivate()
        focusColor.deactivate()
        sharpColor.deactivate()
        spiralColor.deactivate()
        beamColor.deactivate()
        straightColor.deactivate()
        raysColor.deactivate()
        shapeColor.deactivate()
        color.deactivate()
        backgroundColor.deactivate()
        gradientColorA.deactivate()
        gradientColorB.deactivate()
    }

    private func buildGradientControls() {
        typealias Gradient = ImageEffects.GradientBackground
        for (picker, titles, name) in [(gradientShape, Gradient.Shape.allCases.map(\.title), "shape"),
                                        (gradientPattern, Gradient.Pattern.allCases.map(\.title), "pattern")] {
            picker.addItems(withTitles: titles)
            picker.identifier = NSUserInterfaceItemIdentifier("visuals.effects.gradient." + name)
            picker.target = self; picker.action = #selector(changeGradientMode)
            picker.setAccessibilityLabel(name == "shape" ? "グラデーション形状" : "グラデーションの色の並び")
        }
        gradientColorA.identifier = NSUserInterfaceItemIdentifier("visuals.effects.gradient.colorA")
        gradientColorB.identifier = NSUserInterfaceItemIdentifier("visuals.effects.gradient.colorB")
        gradientSwap.identifier = NSUserInterfaceItemIdentifier("visuals.effects.gradient.swap")
        gradientSwap.target = self; gradientSwap.action = #selector(swapGradientColors)
        gradientOutward.identifier = NSUserInterfaceItemIdentifier("visuals.effects.gradient.outward")
        gradientOutward.target = self; gradientOutward.action = #selector(gradientFromCenter)
        let angle = row(numeric(.gradientAngle))
        gradientAngleRow = angle
        gradientProfile.widthAnchor.constraint(equalToConstant: 280).isActive = true
        gradientProfile.heightAnchor.constraint(equalToConstant: 112).isActive = true
        gradientProfile.setAccessibilityLabel("距離に対する色Bの割合とグラデーション見本")
        gradientNotice.textColor = .secondaryLabelColor
        contents[.gradientBackground] = NSStackView(views: [
            row([NSTextField(labelWithString: "色A"), gradientColorA, gradientSwap,
                 NSTextField(labelWithString: "色B"), gradientColorB]),
            row([NSTextField(labelWithString: "形状"), gradientShape,
                 NSTextField(labelWithString: "色の並び"), gradientPattern]),
            row(numeric(.gradientX) + numeric(.gradientY)),
            row(numeric(.gradientPosition) + numeric(.gradientWidth)), angle,
            row(numeric(.gradientBias) + numeric(.gradientOpacity)),
            gradientOutward, gradientProfile, gradientNotice
        ])
    }

    private func updateGradientControls() {
        let value = effects.gradientBackground ?? .init()
        if !gradientColorA.isActive { gradientColorA.color = value.colorA.nsColor }
        if !gradientColorB.isActive { gradientColorB.color = value.colorB.nsColor }
        gradientShape.selectItem(at: ImageEffects.GradientBackground.Shape.allCases.firstIndex(of: value.shape) ?? 0)
        gradientPattern.selectItem(at: ImageEffects.GradientBackground.Pattern.allCases.firstIndex(of: value.pattern) ?? 0)
        for control in [gradientColorA, gradientColorB, gradientShape, gradientPattern, gradientSwap, gradientOutward] as [NSControl] {
            control.isEnabled = editable && effects.gradientBackground != nil
        }
        gradientAngleRow?.isHidden = value.shape == .radial
        gradientOutward.isHidden = value.shape != .radial
        gradientProfile.gradient = value
        let preceding = effects.nodes.prefix { $0.kind != .gradientBackground }
        gradientNotice.isHidden = !preceding.contains { $0.kind == .solidBackground && $0.isEnabled }
    }

    @objc private func changeGradientMode() {
        typealias Gradient = ImageEffects.GradientBackground
        guard editable, selected == .gradientBackground,
              Gradient.Shape.allCases.indices.contains(gradientShape.indexOfSelectedItem),
              Gradient.Pattern.allCases.indices.contains(gradientPattern.indexOfSelectedItem),
              window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        var result = effects
        result.gradientBackground?.shape = Gradient.Shape.allCases[gradientShape.indexOfSelectedItem]
        result.gradientBackground?.pattern = Gradient.Pattern.allCases[gradientPattern.indexOfSelectedItem]
        onCommit?(result)
    }

    @objc private func changeGradientColors(_ sender: SessionColorWell) {
        guard editable, selected == .gradientBackground else { return }
        var result = effects
        result.gradientBackground?.colorA = RGBColor(gradientColorA.color)
        result.gradientBackground?.colorB = RGBColor(gradientColorB.color)
        gradientProfile.gradient = result.gradientBackground ?? .init()
        onColorSession?(sender.sessionID)
        onCommit?(result)
        onColorSession?(nil)
    }

    @objc private func swapGradientColors() {
        guard editable, selected == .gradientBackground, let value = effects.gradientBackground,
              window?.makeFirstResponder(nil) != false else { return }
        cancelDrag(); deactivateColors()
        var result = effects
        result.gradientBackground?.colorA = value.colorB
        result.gradientBackground?.colorB = value.colorA
        onCommit?(result)
    }

    @objc private func gradientFromCenter() {
        guard editable, selected == .gradientBackground, let value = effects.gradientBackground,
              value.shape == .radial, window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        var result = effects
        result.gradientBackground?.position = value.width / 2
        onCommit?(result)
    }

    @objc private func changeSobelMode() {
        let modes = ImageEffects.SobelChromatic.Mode.allCases
        guard editable, selected == .sobelChromatic, modes.indices.contains(sobelMode.indexOfSelectedItem),
              window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        var result = effects
        result.sobelChromatic?.mode = modes[sobelMode.indexOfSelectedItem]
        onCommit?(result)
    }

    @objc private func changeSobelColor() {
        guard editable, selected == .sobelChromatic, sobelColor.isEnabled else { return }
        var result = effects
        result.sobelChromatic?.edgeColor = RGBColor(sobelColor.color)
        onCommit?(result)
    }

    @objc private func changeBinarizationColor(_ sender: NSColorWell) {
        guard editable, selected == .binarization else { return }
        var result = effects
        if sender === binarizationDarkColor { result.binarization?.darkColor = RGBColor(sender.color) }
        else { result.binarization?.lightColor = RGBColor(sender.color) }
        onCommit?(result)
    }

    @objc private func swapBinarizationColors() {
        guard editable, selected == .binarization, window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        deactivateColors()
        var result = effects
        result.binarization?.swapColors()
        onCommit?(result)
    }

    @objc private func changeFlareAutomatic() {
        guard editable, effects.lensFlare != nil, window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        var result = effects
        result.lensFlare?.automaticMotion = flareAutomatic.state == .on
        onCommit?(result)
    }

    @objc private func changeBackgroundColor() {
        guard editable, selected == .solidBackground else { return }
        var result = effects
        result.solidBackground?.color = RGBColor(backgroundColor.color)
        onCommit?(result)
    }

    @objc private func changeColor() {
        guard editable, selected == .particles else { return }
        var result = effects
        result.particles?.color = RGBColor(color.color)
        onCommit?(result)
    }
    @objc private func changeFocusColor() {
        guard editable, selected == .focusLines else { return }
        var result = effects
        result.focusLines?.color = RGBColor(focusColor.color)
        onCommit?(result)
    }
    @objc private func changeSharpColor() {
        guard editable, selected == .sharpFocus else { return }
        var result = effects
        result.sharpFocus?.color = RGBColor(sharpColor.color)
        onCommit?(result)
    }

    private func numeric(_ parameter: ImageParameter) -> [NSView] {
        let effect = parameter.effect!
        let scaled = [.straightSpeed, .straightLength, .raysLength, .gradientWidth].contains(parameter)
        let scale = scaled ? 10.0 : 1.0
        let title = effect.title + (scaled ? "（10" + effect.unit + "）" : "")
        return number(title, initial: effect.initial / scale,
                      range: (effect.range.lowerBound / scale)...(effect.range.upperBound / scale),
                      parameter: { parameter }, read: { effects in effect.read(effects).map { $0 / scale } },
                      update: { effects, value in effect.write(effects, value * scale) })
    }

    private func buildFocusControls() {
        let frequency = number("更新頻度 回/秒", initial: 12, range: 0...30, parameter: { nil },
                               read: { $0.focusLines?.frequency }, update: { effects, value in
            var result = effects
            result.focusLines?.frequency = value
            return result
        })
        focusColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.focusColor")
        contents[.focusLines] = NSStackView(views: [
            row(numeric(.focusX) + numeric(.focusY)),
            row(numeric(.focusWidth) + numeric(.focusHeight)),
            row(numeric(.focusCount) + numeric(.focusThickness)),
            row(numeric(.focusLength) + numeric(.focusVariation)),
            row(frequency + numeric(.focusOpacity)),
            row([NSTextField(labelWithString: "色"), focusColor])
        ])
    }

    @objc private func changeSpiralColor() {
        guard editable, selected == .spiralParticles else { return }
        var result = effects; result.spiralParticles?.color = RGBColor(spiralColor.color)
        onCommit?(result)
    }
    @objc private func changeSpiralDirection() {
        guard editable, selected == .spiralParticles,
              ImageEffects.SpiralParticles.Direction.allCases.indices.contains(spiralDirection.indexOfSelectedItem) else { return }
        var result = effects
        result.spiralParticles?.direction = ImageEffects.SpiralParticles.Direction.allCases[spiralDirection.indexOfSelectedItem]
        onCommit?(result)
    }
    @objc private func shuffleSpiral() {
        guard editable, selected == .spiralParticles else { return }
        var result = effects; result.spiralParticles?.seed = UInt32.random(in: .min ... .max)
        onCommit?(result)
    }

    @objc private func changeBeamColor() {
        guard editable, selected == .electricBeam else { return }
        var result = effects; result.electricBeam?.color = RGBColor(beamColor.color)
        onCommit?(result)
    }

    @objc private func shuffleBeam() {
        guard editable, selected == .electricBeam else { return }
        var result = effects; result.electricBeam?.seed = UInt32.random(in: .min ... .max)
        onCommit?(result)
    }

    @objc private func changeStraightColor() {
        guard editable, selected == .straightLines else { return }
        var result = effects
        result.straightLines?.color = RGBColor(straightColor.color)
        onCommit?(result)
    }

    @objc private func shuffleStraightLines() {
        guard editable, selected == .straightLines else { return }
        var result = effects
        result.straightLines?.seed = UInt32.random(in: .min ... .max)
        onCommit?(result)
    }

    @objc private func changeRaysColor() {
        guard editable, selected == .radialRays else { return }
        var result = effects
        result.radialRays?.color = RGBColor(raysColor.color)
        onCommit?(result)
    }

    @objc private func shuffleRays() {
        guard editable, selected == .radialRays else { return }
        var result = effects
        result.radialRays?.seed = UInt32.random(in: .min ... .max)
        onCommit?(result)
    }

    @objc private func fitRays() {
        guard editable, selected == .radialRays else { return }
        var result = effects
        result.radialRays?.fitAspectRatio(width: Double(VideoExporter.width), height: Double(VideoExporter.height))
        onCommit?(result)
    }

    private func buildRaysControls() {
        let frequency = number("更新頻度 回/秒", initial: 15, range: 0...30, parameter: { nil },
                               read: { $0.radialRays?.frequency }, update: { effects, value in
            var result = effects
            result.radialRays?.frequency = value
            return result
        })
        raysColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.raysColor")
        raysShuffle.target = self; raysShuffle.action = #selector(shuffleRays)
        raysFit.target = self; raysFit.action = #selector(fitRays)
        contents[.radialRays] = NSStackView(views:
            ImageEffects.RadialRays.parameters.map { row(numeric($0)) }
            + [row(frequency), row([raysFit]), row([NSTextField(labelWithString: "色"), raysColor, raysShuffle]),
               NSTextField(wrappingLabelWithString: "長さは中心から長い軸の先端までの距離です。潰れ具合は0%で正円、＋で横長、−で縦長。形状のばらつきで光線の向きが回転するように切り替わり、更新頻度で速さを調整できます。")])
    }

    private func buildStraightControls() {
        straightColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.straightColor")
        straightShuffle.identifier = NSUserInterfaceItemIdentifier("visuals.effects.straightShuffle")
        straightShuffle.target = self
        straightShuffle.action = #selector(shuffleStraightLines)
        let basic: [ImageParameter] = [.straightAngle, .straightCount, .straightLength, .straightThickness, .straightSpeed]
        let detail: [ImageParameter] = [.straightLengthVariation, .straightThicknessVariation, .straightToneVariation, .straightFade, .straightGlow, .straightOpacity]
        contents[.straightLines] = NSStackView(views:
            basic.map { row(numeric($0)) }
            + [NSTextField(labelWithString: "詳細")]
            + detail.map { row(numeric($0)) }
            + [row([NSTextField(labelWithString: "色"), straightColor, straightShuffle]),
               NSTextField(wrappingLabelWithString: "0°は右、90°は下へ流れます。本数は密度の目安です。速度の自動化は位置も変化します。")])
    }

    private func buildSharpControls() {
        let frequency = number("更新頻度 回/秒", initial: 12, range: 0...30, parameter: { nil },
                               read: { $0.sharpFocus?.frequency }, update: { effects, value in
            var result = effects
            result.sharpFocus?.frequency = value
            return result
        })
        sharpColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.sharpColor")
        contents[.sharpFocus] = NSStackView(views: [
            row(numeric(.sharpX) + numeric(.sharpY)),
            row(numeric(.sharpWidth) + numeric(.sharpHeight)),
            row(numeric(.sharpCount) + numeric(.sharpThickness)),
            row(numeric(.sharpLength) + numeric(.sharpVariation)),
            row(frequency + numeric(.sharpOpacity)),
            row(numeric(.sharpTipLength) + numeric(.sharpToneVariation)),
            row([NSTextField(labelWithString: "色"), sharpColor]),
            NSTextField(wrappingLabelWithString: "線ごとの不透明度にばらつきを付けます。太さは線本体の一定幅です。")
        ])
    }

    private func buildShapeControls() {
        for (picker, label) in [(shapeKind, "図形の種類"), (maskKind, "マスクの種類")] {
            picker.addItems(withTitles: ShapeGeometry.Kind.allCases.map(\.title))
            picker.target = self; picker.action = #selector(changeShapeOptions)
            picker.setAccessibilityLabel(label)
        }
        maskInverted.target = self; maskInverted.action = #selector(changeShapeOptions)
        backgroundNotice.target = self; backgroundNotice.action = #selector(toggleBackgroundNotice)
        copyShape.target = self; copyShape.action = #selector(copyShapeToMask)
        shapeColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.shapeColor")
        func geometryRows(_ isMask: Bool) -> [NSView] {
            let parameters: [ImageParameter] = isMask
                ? [.maskWidth, .maskHeight, .maskX, .maskY, .maskRotation, .maskInnerRatio]
                : [.shapeWidth, .shapeHeight, .shapeX, .shapeY, .shapeRotation, .shapeInnerRatio]
            let points = number("星の頂点数", initial: 5, range: ShapeGeometry.pointsRange, parameter: { nil },
                                read: { isMask ? $0.mask?.geometry.points : $0.shape?.geometry.points },
                                update: { effects, value in
                var result = effects
                if isMask { result.mask?.geometry.points = value } else { result.shape?.geometry.points = value }
                return result
            })
            let starRow = row(points + numeric(parameters[5]))
            if isMask { maskStarRows = [starRow] } else { shapeStarRows = [starRow] }
            return [row(numeric(parameters[0]) + numeric(parameters[1])),
                    row(numeric(parameters[2]) + numeric(parameters[3])), row(numeric(parameters[4])), starRow]
        }
        contents[.shape] = NSStackView(views: [row([NSTextField(labelWithString: "種類"), shapeKind, shapeColor])]
            + geometryRows(false) + [row(numeric(.shapeOpacity))])
        contents[.mask] = NSStackView(views: [row([NSTextField(labelWithString: "種類"), maskKind, maskInverted]),
                                                 NSTextField(labelWithString: "この位置までの結果全体を切り抜きます")]
            + geometryRows(true) + [row(numeric(.maskFeather) + numeric(.maskStrength)), row([copyShape]), maskStatus])
        let belowKind = NSPopUpButton()
        belowKind.addItems(withTitles: ShapeGeometry.Kind.allCases.map(\.title))
        belowKind.target = self; belowKind.action = #selector(changeBelowMaskKind(_:))
        belowKind.identifier = NSUserInterfaceItemIdentifier("visuals.effects.belowMaskKind")
        let invert = NSButton(checkboxWithTitle: "反転", target: self, action: #selector(toggleBelowMaskInvert(_:)))
        invert.identifier = NSUserInterfaceItemIdentifier("visuals.effects.belowMaskInvert")
        let points = number("星の頂点数", initial: 5, range: ShapeGeometry.pointsRange, parameter: { nil },
                            read: { $0.belowMask?.geometry.points }, update: { effects, number in
            var result = effects; result.belowMask?.geometry.points = number; return result
        })
        contents[.belowMask] = NSStackView(views: [row([belowKind, invert])]
            + [row(numeric(.belowMaskWidth) + numeric(.belowMaskHeight)),
               row(numeric(.belowMaskX) + numeric(.belowMaskY)), row(numeric(.belowMaskRotation)),
               row(points + numeric(.belowMaskInnerRatio)), row(numeric(.belowMaskFeather) + numeric(.belowMaskStrength)), belowTarget,
               NSTextField(wrappingLabelWithString: "直下固定段のクリップ全体を切り抜きます。チェーンのバイパスとは独立しています。")])
        contents[.belowMask]?.orientation = .vertical
        contents[.belowMask]?.alignment = .leading
        backgroundNotice.isHidden = true
    }

    private func updateShapeControls() {
        if let content = contents[.belowMask] {
            if let picker = content.subviews.flatMap({ $0.subviews }).first(where: { $0.identifier?.rawValue == "visuals.effects.belowMaskKind" }) as? NSPopUpButton {
                picker.selectItem(at: ShapeGeometry.Kind.allCases.firstIndex(of: effects.belowMask?.geometry.kind ?? .rectangle) ?? 0)
                picker.isEnabled = editable
            }
            if let invert = content.subviews.flatMap({ $0.subviews }).first(where: { $0.identifier?.rawValue == "visuals.effects.belowMaskInvert" }) as? NSButton {
                invert.state = effects.belowMask?.inverted == true ? .on : .off; invert.isEnabled = editable
            }
        }

        if let shape = effects.shape {
            shapeKind.selectItem(at: ShapeGeometry.Kind.allCases.firstIndex(of: shape.geometry.kind) ?? 0)
            if !shapeColor.isActive { shapeColor.color = shape.color.nsColor }
        }
        if let mask = effects.mask {
            maskKind.selectItem(at: ShapeGeometry.Kind.allCases.firstIndex(of: mask.geometry.kind) ?? 0)
            maskInverted.state = mask.inverted ? .on : .off
        }
        for control in [shapeKind, maskKind, maskInverted, shapeColor, backgroundNotice] as [NSControl] { control.isEnabled = editable }
        copyShape.isEnabled = editable && effects.shape != nil && effects.mask != nil
        shapeStarRows.forEach { $0.isHidden = effects.shape?.geometry.kind != .star }
        maskStarRows.forEach { $0.isHidden = effects.mask?.geometry.kind != .star }
        backgroundNotice.isHidden = !expanded || (selected != .shape && selected != .mask) || effects.solidBackground == nil
        backgroundNotice.state = effects.solidBackground?.isEnabled == true ? .on : .off
        backgroundNotice.title = backgroundNotice.state == .on ? "単色背景が有効" : "単色背景を有効にする"
        updateMaskStatus()
    }

    private func updateMaskStatus() {
        maskStatus.stringValue = "この位置までの素材・粒子・発光に適用"

    }

    @objc private func changeShapeOptions() {
        guard editable, window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        var result = effects
        if selected == .shape {
            result.shape?.geometry.kind = ShapeGeometry.Kind.allCases[shapeKind.indexOfSelectedItem]
        } else if selected == .mask {
            result.mask?.geometry.kind = ShapeGeometry.Kind.allCases[maskKind.indexOfSelectedItem]
            result.mask?.inverted = maskInverted.state == .on
        }
        onCommit?(result)
    }

    @objc private func toggleBackgroundNotice() {
        guard editable, window?.makeFirstResponder(nil) != false else { return }
        var result = effects
        result.solidBackground?.isEnabled = backgroundNotice.state == .on
        onCommit?(result)
    }

    @objc private func copyShapeToMask() {
        guard editable, window?.makeFirstResponder(nil) != false, let geometry = effects.shape?.geometry else { return }
        cancelDrag()
        var result = effects
        result.mask?.geometry = geometry
        onCommit?(result)
    }

    @objc private func changeShapeColor() {
        guard editable, selected == .shape else { return }
        var result = effects
        result.shape?.color = RGBColor(shapeColor.color)
        onCommit?(result)
    }

}


extension ImageEffectsEditor {
    @objc private func toggleBypass() {
        guard editable else { return }
        cancelDrag()
        var value = effects; value.isBypassed = bypass.state == .on; onCommit?(value)
    }
    @objc private func selectOutputMask() {
        guard editable else { return }
        cancelDrag(); detailsOpen = true; selected = .belowMask
        if effects.belowMask == nil {
            var value = effects; value.belowMask = .init(); onCommit?(value)
        } else { updateControls() }
        if let node = effects.allNodes.first(where: { $0.kind == .belowMask }) { onSelectNode?(node.id) }
    }
    @objc private func changeBelowMaskKind(_ sender: NSPopUpButton) {
        guard editable else { return }
        var value = effects; value.belowMask?.geometry.kind = ShapeGeometry.Kind.allCases[sender.indexOfSelectedItem]; onCommit?(value)
    }
    @objc private func toggleBelowMaskInvert(_ sender: NSButton) {
        guard editable else { return }
        var value = effects; value.belowMask?.inverted = sender.state == .on; onCommit?(value)
    }
    private func chainMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        guard let index = effects.nodes.firstIndex(where: { $0.id == id }) else { return menu }
        for (title, target) in [("上へ移動", index - 1), ("下へ移動", index + 1)] {
            menu.addItem(EffectMenuItem(title, enabled: effects.nodes.indices.contains(target)) { [weak self] in
                guard let self else { return }; self.cancelDrag()
                var value = self.effects; value.move(id, to: target); self.onCommit?(value)
            })
        }
        let insert = NSMenuItem(title: "この後に追加", action: nil, keyEquivalent: "")
        insert.submenu = additionMenu(after: id); menu.addItem(insert)
        menu.addItem(EffectMenuItem("削除") { [weak self] in
            guard let self else { return }; var value = self.effects
            value.nodes.removeAll { $0.id == id }; self.onCommit?(value)
        })
        return menu
    }
}
