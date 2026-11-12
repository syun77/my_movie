import AppKit

@MainActor
final class ImageEffectsEditor: NSStackView, NSTextFieldDelegate {
    var onCommit: ((ImageEffects) -> Void)?
    var onPreview: ((ImageEffects?) -> Void)?
    private enum Kind: Int, CaseIterable {
        case blur, bloom, particles, embers, snow, orbs

        var title: String {
            switch self {
            case .blur: return "ガウスブラー"
            case .bloom: return "ブルーム"
            case .particles: return "光の粒子"
            case .embers: return "舞い上がる火の粉"
            case .snow: return "雪"
            case .orbs: return "光の粒子2"
            }
        }

        func exists(in effects: ImageEffects) -> Bool {
            switch self {
            case .blur: return effects.blur != nil
            case .bloom: return effects.bloom != nil
            case .particles: return effects.particles != nil
            case .embers: return effects.embers != nil
            case .snow: return effects.snow != nil
            case .orbs: return effects.orbs != nil
            }
        }
    }

    private struct NumberInput {
        let field: DragValueField
        let read: (ImageEffects) -> Double?
        let write: (ImageEffects, Double) -> ImageEffects
    }

    private let disclosure = NSButton(title: "▸ 追加演出", target: nil, action: nil)
    private let outside = NSTextField(labelWithString: "クリップ区間外")
    private let add = NSPopUpButton(frame: .zero, pullsDown: true)
    private let selection = NSPopUpButton()
    private let enabled = NSButton(checkboxWithTitle: "有効", target: nil, action: nil)
    private let remove = NSButton(title: "削除", target: nil, action: nil)
    private let color = NSColorWell()
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
    var time = 0.0 { didSet { updateOutside() } }

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
        color.target = self; color.action = #selector(changeColor)
        color.colorWellStyle = .minimal
        color.isContinuous = false
        color.setAccessibilityLabel("光の粒子の色")
        color.widthAnchor.constraint(equalToConstant: 32).isActive = true
        color.heightAnchor.constraint(equalToConstant: 22).isActive = true

        emitterPicker.setAccessibilityLabel("光の粒子の発生源")
        emitterPicker.target = self; emitterPicker.action = #selector(selectEmitter)
        addEmitter.setAccessibilityLabel("発生源を追加")
        addEmitter.target = self; addEmitter.action = #selector(insertEmitter)
        removeEmitter.setAccessibilityLabel("発生源を削除")
        removeEmitter.target = self; removeEmitter.action = #selector(deleteEmitter)

        typealias Blur = ImageEffects.Blur
        typealias Bloom = ImageEffects.Bloom
        typealias Particles = ImageEffects.Particles
        typealias Embers = ImageEffects.Embers
        contents[.blur] = row(number("半径 px", \.blur, \.radius, Blur().radius, Blur.radiusRange))
        contents[.bloom] = row(number("しきい値 %", \.bloom, \.threshold, Bloom().threshold, Bloom.thresholdRange)
            + number("半径 px", \.bloom, \.radius, Bloom().radius, Bloom.radiusRange)
            + number("強さ %", \.bloom, \.intensity, Bloom().intensity, Bloom.intensityRange))
        let particleDefaults = Particles(seed: 0)
        contents[.particles] = NSStackView(views: [
            row(number("個数", \.particles, \.count, particleDefaults.count, Particles.countRange)
                + number("基準直径 px", \.particles, \.diameter, particleDefaults.diameter, Particles.diameterRange)
                + number("基準速度 px/秒", \.particles, \.speed, particleDefaults.speed, Particles.speedRange)),
            row(number("曲線の強さ %", \.particles, \.curveStrength, particleDefaults.curveStrength, Particles.curveStrengthRange)
                + number("不透明度 %", \.particles, \.opacity, particleDefaults.opacity, Particles.opacityRange)
                + [NSTextField(labelWithString: "色"), color]),
            row([NSTextField(labelWithString: "発生源"), emitterPicker, addEmitter, removeEmitter]
                + emitterCoordinate("X", \.x, Particles.Emitter.xRange)
                + emitterCoordinate("Y", \.y, Particles.Emitter.yRange))
        ])
        let emberDefaults = Embers(seed: 0)
        contents[.embers] = NSStackView(views: [
            row(number("個数", \.embers, \.count, emberDefaults.count, Embers.countRange)
                + number("大きさ px", \.embers, \.diameter, emberDefaults.diameter, Embers.diameterRange)
                + number("上昇速度 px/秒", \.embers, \.riseSpeed, emberDefaults.riseSpeed, Embers.riseSpeedRange)),
            row(number("横風 px/秒", \.embers, \.wind, emberDefaults.wind, Embers.windRange)
                + number("揺れの速さ %", \.embers, \.swaySpeed, emberDefaults.swaySpeed, Embers.swaySpeedRange)
                + number("明るさ %", \.embers, \.brightness, emberDefaults.brightness, Embers.brightnessRange))
        ])
        typealias Snow = ImageEffects.Snow
        let snowDefaults = Snow(seed: 0)
        contents[.snow] = NSStackView(views: [
            row(number("個数", \.snow, \.count, snowDefaults.count, Snow.countRange)
                + number("大きさ px", \.snow, \.diameter, snowDefaults.diameter, Snow.diameterRange)
                + number("落下速度 px/秒", \.snow, \.fallSpeed, snowDefaults.fallSpeed, Snow.fallSpeedRange)),
            row(number("横風 %", \.snow, \.wind, snowDefaults.wind, Snow.windRange)
                + number("不透明度 %", \.snow, \.opacity, snowDefaults.opacity, Snow.opacityRange))
        ])
        typealias Orbs = ImageEffects.Orbs
        let orbDefaults = Orbs()
        contents[.orbs] = NSStackView(views: [
            row(number("発生数", \.orbs, \.count, orbDefaults.count, Orbs.countRange)
                + number("彩度 %", \.orbs, \.saturation, orbDefaults.saturation, Orbs.saturationRange)),
            row(number("速度 %", \.orbs, \.speed, orbDefaults.speed, Orbs.speedRange)
                + number("不透明度 %", \.orbs, \.opacity, orbDefaults.opacity, Orbs.opacityRange))
        ])
        for kind in [Kind.particles, .embers, .snow, .orbs] {
            contents[kind]?.orientation = .vertical
            contents[kind]?.alignment = .leading
            contents[kind]?.spacing = 4
        }
        addArrangedSubview(row([disclosure, outside]))
        addArrangedSubview(toolbar)
        for kind in Kind.allCases {
            if let content = contents[kind] { addArrangedSubview(content) }
        }
        updateControls()
    }

    required init?(coder: NSCoder) { nil }

    func load(_ clip: VisualClip?, editable: Bool) {
        if clip?.id != shownClip?.id { selectedEmitter = 0 }
        if clip?.id != shownClip?.id || !editable { color.deactivate() }
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

    private func number<T>(_ title: String, _ effect: WritableKeyPath<ImageEffects, T?>,
                           _ value: WritableKeyPath<T, Double>, _ initial: Double,
                           _ range: ClosedRange<Double>) -> [NSView] {
        number(title, initial: initial, range: range, read: { $0[keyPath: effect]?[keyPath: value] }) { effects, number in
            var result = effects
            result[keyPath: effect]?[keyPath: value] = number
            return result
        }
    }

    private func emitterCoordinate(_ title: String, _ coordinate: WritableKeyPath<ImageEffects.Particles.Emitter, Double>,
                                   _ range: ClosedRange<Double>) -> [NSView] {
        number(title, initial: ImageEffects.Particles.Emitter()[keyPath: coordinate], range: range,
               accessibilityLabel: "発生源の" + title, read: { [weak self] effects in
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
        numbers.append(NumberInput(field: field, read: read, write: write))
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
        case .blur: enabled.state = effects.blur?.isEnabled == true ? .on : .off
        case .bloom: enabled.state = effects.bloom?.isEnabled == true ? .on : .off
        case .particles: enabled.state = effects.particles?.isEnabled == true ? .on : .off
        case .embers: enabled.state = effects.embers?.isEnabled == true ? .on : .off
        case .snow: enabled.state = effects.snow?.isEnabled == true ? .on : .off
        case .orbs: enabled.state = effects.orbs?.isEnabled == true ? .on : .off
        case nil: enabled.state = .off
        }
        if let particles = effects.particles, !color.isActive { color.color = particles.color.nsColor }
        color.isEnabled = editable
        updateEmitterControls()
        for input in numbers {
            let value = input.read(effects)
            input.field.isEnabled = editable && value != nil
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
        particles.emitters.remove(at: selectedEmitter)
        selectedEmitter = min(selectedEmitter, particles.emitters.count - 1)
        var result = effects
        result.particles = particles
        onCommit?(result)
    }

    @objc private func toggleDisclosure() {
        guard window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        expanded.toggle()
        if !expanded { color.deactivate() }
        updateControls()
    }

    @objc private func selectEffect() {
        let kind = Kind(rawValue: selection.selectedTag())
        guard window?.makeFirstResponder(nil) != false else { return }
        cancelDrag()
        color.deactivate()
        selected = kind
        updateControls()
    }

    @objc private func addEffect(_ sender: NSMenuItem) {
        guard editable, let kind = Kind(rawValue: sender.tag), !kind.exists(in: effects),
              window?.makeFirstResponder(nil) != false else { return }
        var result = effects
        switch kind {
        case .blur: result.blur = .init()
        case .bloom: result.bloom = .init()
        case .particles: result.particles = .init()
        case .embers: result.embers = .init()
        case .snow: result.snow = .init()
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
        case .blur: result.blur?.isEnabled = isEnabled
        case .bloom: result.bloom?.isEnabled = isEnabled
        case .particles: result.particles?.isEnabled = isEnabled
        case .embers: result.embers?.isEnabled = isEnabled
        case .snow: result.snow?.isEnabled = isEnabled
        case .orbs: result.orbs?.isEnabled = isEnabled
        case nil: return
        }
        onCommit?(result)
    }

    @objc private func removeEffect() {
        guard editable, window?.makeFirstResponder(nil) != false else { return }
        color.deactivate()
        var result = effects
        switch selected {
        case .blur: result.blur = nil
        case .bloom: result.bloom = nil
        case .particles: result.particles = nil
        case .embers: result.embers = nil
        case .snow: result.snow = nil
        case .orbs: result.orbs = nil
        case nil: return
        }
        onCommit?(result)
    }

    @objc private func changeColor() {
        guard editable, selected == .particles else { return }
        var result = effects
        result.particles?.color = RGBColor(color.color)
        onCommit?(result)
    }
}
