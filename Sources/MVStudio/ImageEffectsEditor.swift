import AppKit

@MainActor
final class ImageEffectsEditor: NSStackView, NSTextFieldDelegate {
    var onDeleteEmitter: ((ImageEffects, Int) -> Void)?
    var onCreateAutomation: ((ImageParameter) -> Void)?
    var onEditMusic: ((ImageParameter) -> Void)?
    var onRemoveMusic: ((ImageParameter) -> Void)?
    var onRemoveAutomation: ((ImageParameter) -> Void)?
    var onCommit: ((ImageEffects) -> Void)?
    var onPreview: ((ImageEffects?) -> Void)?
    private enum Kind: Int, CaseIterable {
        case blur, bloom, particles, embers, snow, orbs, shake, colorCorrection, solidBackground, shape, mask

        var title: String {
            switch self {
            case .shape: return "図形"
            case .mask: return "マスク"
            case .solidBackground: return "単色背景"
            case .blur: return "ガウスブラー"
            case .bloom: return "ブルーム"
            case .particles: return "光の粒子"
            case .embers: return "舞い上がる火の粉"
            case .snow: return "雪"
            case .orbs: return "光の粒子2"
            case .shake: return "シェイク"
            case .colorCorrection: return "色調補正"
            }
        }

        func exists(in effects: ImageEffects) -> Bool {
            switch self {
            case .shape: return effects.shape != nil
            case .mask: return effects.mask != nil
            case .solidBackground: return effects.solidBackground != nil
            case .blur: return effects.blur != nil
            case .bloom: return effects.bloom != nil
            case .particles: return effects.particles != nil
            case .embers: return effects.embers != nil
            case .snow: return effects.snow != nil
            case .orbs: return effects.orbs != nil
            case .shake: return effects.shake != nil
            case .colorCorrection: return effects.colorCorrection != nil
            }
        }
    }

    private struct NumberInput {
        let field: DragValueField
        let parameter: () -> ImageParameter?
        let read: (ImageEffects) -> Double?
        let write: (ImageEffects, Double) -> ImageEffects
    }

    private let disclosure = NSButton(title: "▸ 追加演出", target: nil, action: nil)
    private let outside = NSTextField(labelWithString: "クリップ区間外")
    private let add = NSPopUpButton(frame: .zero, pullsDown: true)
    private let selection = NSPopUpButton()
    private let enabled = NSButton(checkboxWithTitle: "有効", target: nil, action: nil)
    private let remove = NSButton(title: "削除", target: nil, action: nil)
    private let shapeColor = NSColorWell()
    private let shapeKind = NSPopUpButton()
    private let maskKind = NSPopUpButton()
    private let maskTarget = NSPopUpButton()
    private let maskInverted = NSButton(checkboxWithTitle: "反転", target: nil, action: nil)
    private let maskStatus = NSTextField(wrappingLabelWithString: "")
    private let backgroundNotice = NSButton(checkboxWithTitle: "単色背景が有効", target: nil, action: nil)
    private let copyShape = NSButton(title: "図形をマスクへコピー", target: nil, action: nil)
    private var shapeStarRows: [NSView] = []
    private var maskStarRows: [NSView] = []
    private var track = VisualTrack()
    private let color = NSColorWell()
    private let backgroundColor = NSColorWell()
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
    private lazy var toolbar = row([selection, enabled, remove, add])
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
        add.addItem(withTitle: "＋ 演出を追加")
        add.item(at: 0)?.tag = -1
        add.menu?.autoenablesItems = false
        for kind in Kind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(addEffect(_:)), keyEquivalent: "")
            item.target = self; item.tag = kind.rawValue
            add.menu?.addItem(item)
        }
        selection.target = self; selection.action = #selector(selectEffect)
        selection.setAccessibilityLabel("設定する演出")
        enabled.target = self; enabled.action = #selector(toggleEffect)
        remove.target = self; remove.action = #selector(removeEffect)
        for (well, action, label) in [(color, #selector(changeColor), "光の粒子の色"),
                                      (backgroundColor, #selector(changeBackgroundColor), "単色背景の色"),
                                      (shapeColor, #selector(changeShapeColor), "図形の色")] {
            well.target = self; well.action = action
            well.colorWellStyle = .minimal
            well.isContinuous = true
            well.setAccessibilityLabel(label)
            well.widthAnchor.constraint(equalToConstant: 32).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        backgroundColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.backgroundColor")
        contents[.solidBackground] = row([NSTextField(labelWithString: "色"), backgroundColor])

        emitterPicker.setAccessibilityLabel("光の粒子の発生源")
        emitterPicker.target = self; emitterPicker.action = #selector(selectEmitter)
        addEmitter.setAccessibilityLabel("発生源を追加")
        addEmitter.target = self; addEmitter.action = #selector(insertEmitter)
        removeEmitter.setAccessibilityLabel("発生源を削除")
        removeEmitter.target = self; removeEmitter.action = #selector(deleteEmitter)

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
        contents[.blur] = row(number("半径 px", .blurRadius, \.blur, \.radius, Blur().radius, Blur.radiusRange))
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
        buildShapeControls()
        for kind in [Kind.particles, .embers, .snow, .orbs, .shape, .mask] {
            contents[kind]?.orientation = .vertical
            contents[kind]?.alignment = .leading
            contents[kind]?.spacing = 4
        }
        addArrangedSubview(row([disclosure, outside]))
        addArrangedSubview(toolbar)
        addArrangedSubview(backgroundNotice)
        for kind in Kind.allCases {
            if let content = contents[kind] { addArrangedSubview(content) }
        }
        updateControls()
    }

    required init?(coder: NSCoder) { nil }

    func load(_ clip: VisualClip?, editable: Bool, track: VisualTrack? = nil) {
        if let track { self.track = track }
        if clip?.id != shownClip?.id { selectedEmitter = 0 }
        if clip?.id != shownClip?.id || !editable { deactivateColors() }
        shownClip = clip
        effects = clip?.effects ?? ImageEffects()
        self.editable = editable && clip != nil
        updateControls()
    }

    @discardableResult
    func cancelDrag() -> Bool {
        numbers.contains { $0.field.cancelNumberDrag() }
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.alignment = .centerY
        stack.spacing = 6
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
        field.widthAnchor.constraint(equalToConstant: 76).isActive = true
        field.alignment = .right
        field.knobRange = range
        field.setAccessibilityLabel(accessibilityLabel ?? title)
        field.delegate = self
        let write: (ImageEffects, Double) -> ImageEffects = { effects, value in
            update(effects, min(range.upperBound, max(range.lowerBound, value.rounded())))
        }
        field.bindNumber(current: { [weak self] in self.flatMap { read($0.effects) } },
                         initial: { initial }, normalize: { min(range.upperBound, max(range.lowerBound, $0)) },
                         preview: { [weak self] value in
            guard let self else { return }
            self.onPreview?(value.map { write(self.effects, $0) })
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
        let group = NSStackView(views: [NSTextField(labelWithString: title), field])
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
        if let value, value.isFinite { onCommit?(input.write(effects, value)) }
    }

    private func updateOutside() {
        let inside = shownClip.map { $0.start <= time && time < $0.end } ?? true
        let hidden = !expanded || inside
        if outside.isHidden != hidden { outside.isHidden = hidden }
    }

    private func updateControls() {
        let kinds = Kind.allCases.filter { $0.exists(in: effects) }
        if selected.map({ !kinds.contains($0) }) ?? true { selected = kinds.first }
        if selection.itemArray.map(\.tag) != kinds.map(\.rawValue) {
            selection.removeAllItems()
            for kind in kinds {
                selection.addItem(withTitle: kind.title)
                selection.lastItem?.tag = kind.rawValue
            }
        }
        if let selected { selection.selectItem(withTag: selected.rawValue) }
        for kind in Kind.allCases {
            add.menu?.item(withTag: kind.rawValue)?.isEnabled = editable && !kind.exists(in: effects)
            contents[kind]?.isHidden = !expanded || selected != kind
        }
        disclosure.isEnabled = editable || expanded
        disclosure.title = expanded ? "▾ 追加演出" : "▸ 追加演出"
        toolbar.isHidden = !expanded
        selection.isEnabled = editable && !kinds.isEmpty
        add.isEnabled = editable && kinds.count < Kind.allCases.count
        enabled.isEnabled = selection.isEnabled
        remove.isEnabled = selection.isEnabled
        switch selected {
        case .shape: enabled.state = effects.shape?.isEnabled == true ? .on : .off
        case .mask: enabled.state = effects.mask?.isEnabled == true ? .on : .off
        case .solidBackground: enabled.state = effects.solidBackground?.isEnabled == true ? .on : .off
        case .blur: enabled.state = effects.blur?.isEnabled == true ? .on : .off
        case .bloom: enabled.state = effects.bloom?.isEnabled == true ? .on : .off
        case .particles: enabled.state = effects.particles?.isEnabled == true ? .on : .off
        case .embers: enabled.state = effects.embers?.isEnabled == true ? .on : .off
        case .snow: enabled.state = effects.snow?.isEnabled == true ? .on : .off
        case .shake: enabled.state = effects.shake?.isEnabled == true ? .on : .off
        case .colorCorrection: enabled.state = effects.colorCorrection?.isEnabled == true ? .on : .off
        case .orbs: enabled.state = effects.orbs?.isEnabled == true ? .on : .off
        case nil: enabled.state = .off
        }
        if let particles = effects.particles, !color.isActive { color.color = particles.color.nsColor }
        color.isEnabled = editable
        if let background = effects.solidBackground, !backgroundColor.isActive { backgroundColor.color = background.color.nsColor }
        backgroundColor.isEnabled = editable
        updateShapeControls()
        updateEmitterControls()
        for input in numbers {
            let value = input.read(effects)
            input.field.isEnabled = editable && value != nil
            input.field.identifier = input.parameter().map { NSUserInterfaceItemIdentifier("visuals.value." + $0.rawValue) }
            input.field.hasMusic = input.parameter().flatMap { shownClip?.audioModulations[$0] } != nil
            input.field.hasAutomation = input.parameter().flatMap { shownClip?.curve($0) } != nil
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

    @objc private func selectEffect() {
        let kind = Kind(rawValue: selection.selectedTag())
        guard window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        deactivateColors()
        selected = kind
        updateControls()
    }

    @objc private func addEffect(_ sender: NSMenuItem) {
        guard editable, let kind = Kind(rawValue: sender.tag), !kind.exists(in: effects),
              window?.makeFirstResponder(nil) != false else { return }
        var result = effects
        switch kind {
        case .shape: result.shape = .init()
        case .mask: result.mask = .init()
        case .solidBackground: result.solidBackground = .init()
        case .blur: result.blur = .init()
        case .bloom: result.bloom = .init()
        case .particles: result.particles = .init()
        case .embers: result.embers = .init()
        case .snow: result.snow = .init()
        case .shake: result.shake = .init()
        case .colorCorrection: result.colorCorrection = .init()
        case .orbs: result.orbs = .init()
        }
        selected = kind
        onCommit?(result)
    }

    @objc private func toggleEffect() {
        let isEnabled = enabled.state == .on
        guard editable, window?.makeFirstResponder(nil) != false else { return }
        var result = effects
        switch selected {
        case .shape: result.shape?.isEnabled = isEnabled
        case .mask: result.mask?.isEnabled = isEnabled
        case .solidBackground: result.solidBackground?.isEnabled = isEnabled
        case .blur: result.blur?.isEnabled = isEnabled
        case .bloom: result.bloom?.isEnabled = isEnabled
        case .particles: result.particles?.isEnabled = isEnabled
        case .embers: result.embers?.isEnabled = isEnabled
        case .snow: result.snow?.isEnabled = isEnabled
        case .shake: result.shake?.isEnabled = isEnabled
        case .colorCorrection: result.colorCorrection?.isEnabled = isEnabled
        case .orbs: result.orbs?.isEnabled = isEnabled
        case nil: return
        }
        onCommit?(result)
    }

    @objc private func removeEffect() {
        guard editable, window?.makeFirstResponder(nil) != false else { return }
        deactivateColors()
        var result = effects
        switch selected {
        case .shape: result.shape = nil
        case .mask: result.mask = nil
        case .solidBackground: result.solidBackground = nil
        case .blur: result.blur = nil
        case .bloom: result.bloom = nil
        case .particles: result.particles = nil
        case .embers: result.embers = nil
        case .snow: result.snow = nil
        case .shake: result.shake = nil
        case .colorCorrection: result.colorCorrection = nil
        case .orbs: result.orbs = nil
        case nil: return
        }
        onCommit?(result)
    }

    private func deactivateColors() {
        shapeColor.deactivate()
        color.deactivate()
        backgroundColor.deactivate()
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
    private func buildShapeControls() {
        for (picker, label) in [(shapeKind, "図形の種類"), (maskKind, "マスクの種類")] {
            picker.addItems(withTitles: ShapeGeometry.Kind.allCases.map(\.title))
            picker.target = self; picker.action = #selector(changeShapeOptions)
            picker.setAccessibilityLabel(label)
        }
        maskTarget.addItems(withTitles: ImageEffects.Mask.Target.allCases.map(\.title))
        maskTarget.target = self; maskTarget.action = #selector(changeShapeOptions)
        maskTarget.identifier = NSUserInterfaceItemIdentifier("visuals.effects.maskTarget")
        maskTarget.menu?.autoenablesItems = false
        maskInverted.target = self; maskInverted.action = #selector(changeShapeOptions)
        backgroundNotice.target = self; backgroundNotice.action = #selector(toggleBackgroundNotice)
        copyShape.target = self; copyShape.action = #selector(copyShapeToMask)
        shapeColor.identifier = NSUserInterfaceItemIdentifier("visuals.effects.shapeColor")
        func numeric(_ parameter: ImageParameter) -> [NSView] {
            let effect = parameter.effect!
            return number(effect.title, initial: effect.initial, range: effect.range, parameter: { parameter },
                          read: effect.read, update: effect.write)
        }
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
                                                 row([maskTarget])]
            + geometryRows(true) + [row(numeric(.maskFeather) + numeric(.maskStrength)), row([copyShape]), maskStatus])
        backgroundNotice.isHidden = true
    }

    private func updateShapeControls() {
        if let shape = effects.shape {
            shapeKind.selectItem(at: ShapeGeometry.Kind.allCases.firstIndex(of: shape.geometry.kind) ?? 0)
            if !shapeColor.isActive { shapeColor.color = shape.color.nsColor }
        }
        if let mask = effects.mask {
            maskKind.selectItem(at: ShapeGeometry.Kind.allCases.firstIndex(of: mask.geometry.kind) ?? 0)
            maskTarget.selectItem(at: ImageEffects.Mask.Target.allCases.firstIndex(of: mask.target) ?? 0)
            maskInverted.state = mask.inverted ? .on : .off
        }
        for control in [shapeKind, maskKind, maskTarget, maskInverted, shapeColor, backgroundNotice] as [NSControl] { control.isEnabled = editable }
        copyShape.isEnabled = editable && effects.shape != nil && effects.mask != nil
        maskTarget.item(at: 1)?.isEnabled = (shownClip.flatMap { track.slot(of: $0.id) } ?? 1) > 1
        shapeStarRows.forEach { $0.isHidden = effects.shape?.geometry.kind != .star }
        maskStarRows.forEach { $0.isHidden = effects.mask?.geometry.kind != .star }
        backgroundNotice.isHidden = !expanded || (selected != .shape && selected != .mask) || effects.solidBackground == nil
        backgroundNotice.state = effects.solidBackground?.isEnabled == true ? .on : .off
        backgroundNotice.title = backgroundNotice.state == .on ? "単色背景が有効" : "単色背景を有効にする"
        updateMaskStatus()
    }

    private func updateMaskStatus() {
        guard let mask = effects.mask else { return }
        if mask.target == .image { maskStatus.stringValue = "粒子は対象外"; return }
        let slot = shownClip.flatMap { track.slot(of: $0.id) } ?? 1
        let target = track.layers.first { $0.slot == slot - 1 }?.clips.first { $0.start <= time && time < $0.end }
        let inside = shownClip.map { $0.start <= time && time < $0.end } ?? false
        maskStatus.stringValue = inside && target != nil ? "直下のクリップ全体（粒子を含む）に適用" : "対象なし（直下の段に有効なクリップがありません）"
    }

    @objc private func changeShapeOptions() {
        guard editable, window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        var result = effects
        if selected == .shape {
            result.shape?.geometry.kind = ShapeGeometry.Kind.allCases[shapeKind.indexOfSelectedItem]
        } else if selected == .mask {
            result.mask?.geometry.kind = ShapeGeometry.Kind.allCases[maskKind.indexOfSelectedItem]
            result.mask?.target = ImageEffects.Mask.Target.allCases[maskTarget.indexOfSelectedItem]
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
