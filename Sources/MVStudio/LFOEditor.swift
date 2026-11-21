import AppKit

@MainActor
final class LFOEditor: NSStackView, NSTextFieldDelegate {
    var onCommit: ((ImageParameter, ParameterAutomation.Mode, LFOSettings?) -> Void)?
    var onPreview: ((ImageParameter, LFOSettings?) -> Void)?
    var onSelect: ((ImageParameter) -> Void)?
    var settings = SceneSettings() { didSet { refreshStatus() } }
    private var detailRows: [NSView] = []
    private let picker = NSPopUpButton()
    private let mode = NSPopUpButton()
    private let timebase = NSPopUpButton()
    private let period = NSPopUpButton()
    private let origin = NSPopUpButton()
    private let bipolar = NSButton(checkboxWithTitle: "Bipolar（±）", target: nil, action: nil)
    private let reset = NSButton(title: "LFO設定を初期化", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let preview = LFOWaveformView(frame: .zero)
    private let hzRow = NSStackView(), beatRow = NSStackView()
    private var fields: [Number: DragValueField] = [:]
    private var parameters: [ImageParameter] = []
    private var clip: VisualClip?
    private var editable = false
    private(set) var parameter: ImageParameter = .scale
    private var model: LFOSettings { clip?.automation(parameter)?.lfo ?? LFOSettings() }
    private enum Number: String, CaseIterable {
        case frequency, phase, tilt, curve, amount
        var title: String {
            switch self { case .frequency: return "周波数 Hz"; case .phase: return "位相 °"; case .tilt: return "Waveform Tilt %"; case .curve: return "Waveform Curve %"; case .amount: return "Amount" }
        }
        var key: WritableKeyPath<LFOSettings, Double> {
            switch self { case .frequency: return \.frequencyHz; case .phase: return \.phaseDegrees; case .tilt: return \.tilt; case .curve: return \.curve; case .amount: return \.amount }
        }
        func range(_ parameter: ImageParameter) -> ClosedRange<Double> {
            switch self { case .frequency: return 0.01...20; case .phase: return 0...360; case .tilt, .curve: return -100...100; case .amount: return 0...parameter.lfoAmountMaximum }
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 5
        let title = NSTextField(labelWithString: "オートメーション")
        title.font = .boldSystemFont(ofSize: 12)
        row([title, picker]); row([NSTextField(labelWithString: "モード"), mode, reset])
        picker.widthAnchor.constraint(equalToConstant: 185).isActive = true
        mode.addItems(withTitles: ["キー", "LFO"])
        timebase.addItems(withTitles: ["Hz", "ビート同期"])
        period.addItems(withTitles: LFOSettings.BeatPeriod.choices.map(\.title))
        origin.addItems(withTitles: ["曲に同期", "クリップ開始"])
        for (control, id) in [(picker,"parameter"), (mode,"mode"), (timebase,"timebase"), (period,"period"), (origin,"origin"), (bipolar,"bipolar"), (reset,"reset")] as [(NSControl, String)] {
            control.identifier = NSUserInterfaceItemIdentifier("lfo." + id)
            control.target = self; control.action = #selector(changeOption(_:))
        }
        row([NSTextField(labelWithString: "時間単位"), timebase])
        hzRow.spacing = 6; beatRow.spacing = 6
        addArrangedSubview(hzRow); addArrangedSubview(beatRow)
        beatRow.addArrangedSubview(NSTextField(labelWithString: "周期")); beatRow.addArrangedSubview(period)
        row([NSTextField(labelWithString: "位相基準"), origin])
        for number in Number.allCases {
            let field = DragValueField(frame: .zero); fields[number] = field
            field.identifier = NSUserInterfaceItemIdentifier("lfo." + number.rawValue)
            field.widthAnchor.constraint(equalToConstant: 112).isActive = true
            field.delegate = self; field.target = self; field.action = #selector(confirmNumber(_:))
            if number == .frequency {
                hzRow.addArrangedSubview(NSTextField(labelWithString: number.title)); hzRow.addArrangedSubview(field)
            } else { row([NSTextField(labelWithString: number.title), field]) }
            field.bindNumber(step: number == .frequency ? 0.01 : 1, current: { [weak self] in self?.model[keyPath: number.key] },
                             initial: { LFOSettings()[keyPath: number.key] },
                             normalize: { [weak self] value in
                let range = number.range(self?.parameter ?? .scale)
                return min(range.upperBound, max(range.lowerBound, value))
            }, adjustment: number == .frequency ? { initial, distance in initial * pow(2, distance / 50) } : nil,
                             preview: { [weak self, weak field] value in
                guard let self else { return }
                if let value {
                    var model = self.model; self.write(value, number: number, model: &model)
                    field?.doubleValue = model[keyPath: number.key]
                    self.preview.model = model; self.refreshStatus(model)
                    self.onPreview?(self.parameter, model)
                } else {
                    self.preview.model = self.model; self.refreshStatus()
                    self.onPreview?(self.parameter, nil)
                }
            }, commit: { [weak self] value in self?.commit(value, number: number) })
        }
        fields[.tilt]?.toolTip = "下降ランプ ← 対称 → 上昇ランプ。" + DragValueField.numberEditingHint
        fields[.curve]?.toolTip = "矩形 ← 三角 → サイン状。" + DragValueField.numberEditingHint
        row([bipolar])
        preview.heightAnchor.constraint(equalToConstant: 72).isActive = true
        addArrangedSubview(preview); preview.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        addArrangedSubview(status); status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        detailRows = Array(arrangedSubviews.dropFirst(2))
        load(nil, editable: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func row(_ views: [NSView]) {
        let row = NSStackView(views: views); row.spacing = 6; addArrangedSubview(row)
    }
    func load(_ clip: VisualClip?, editable: Bool) {
        self.clip = clip; self.editable = editable
        let available = ImageParameter.allCases.filter { $0.effectKind == nil || $0.effect?.read(clip?.effects ?? ImageEffects()) != nil }
        if available != parameters { parameters = available; picker.removeAllItems(); picker.addItems(withTitles: available.map(\.title)) }
        if !parameters.contains(parameter) { parameter = .scale }
        picker.selectItem(withTitle: parameter.title)
        let active = clip?.activeLFO(parameter) != nil
        picker.isEnabled = editable && clip != nil; mode.isEnabled = picker.isEnabled
        isHidden = clip == nil
        detailRows.forEach { $0.isHidden = !active }
        reset.isHidden = !active
        mode.selectItem(at: active ? 1 : 0)
        for control in [timebase, period, origin, bipolar, reset] as [NSControl] { control.isEnabled = editable && active }
        let model = self.model
        timebase.selectItem(at: model.timebase == .hertz ? 0 : 1)
        period.selectItem(at: LFOSettings.BeatPeriod.choices.firstIndex { $0.period == model.beatsPerCycle } ?? 12)
        origin.selectItem(at: model.phaseOrigin == .song ? 0 : 1)
        bipolar.state = model.bipolar ? .on : .off
        for (number, field) in fields {
            field.isEnabled = editable && active
            field.knobRange = number.range(parameter)
            if field.currentEditor() == nil { field.doubleValue = model[keyPath: number.key] }
        }
        fields[.amount]?.setAccessibilityLabel("Amount " + parameter.lfoAmountUnit)
        fields[.amount]?.toolTip = "片振幅（" + parameter.lfoAmountUnit + "）。" + DragValueField.numberEditingHint
        hzRow.isHidden = !active || model.timebase != .hertz
        beatRow.isHidden = !active || model.timebase == .hertz
        preview.model = model; preview.alphaValue = active ? 1 : 0.35
        refreshStatus()
    }
    func select(_ parameter: ImageParameter, notify: Bool = true) {
        guard self.parameter != parameter else { return }
        cancelDrag(); self.parameter = parameter; load(clip, editable: editable)
        if notify { onSelect?(parameter) }
    }
    @discardableResult func cancelDrag() -> Bool {
        var cancelled = false
        for field in fields.values { cancelled = field.cancelNumberDrag() || cancelled }
        return cancelled
    }
    private func refreshStatus(_ draft: LFOSettings? = nil) {
        let model = draft ?? self.model, hz = (draft ?? self.model).frequency(bpm: settings.bpm)
        status.stringValue = String(format: "%.4g Hz・1周期 %.4g 秒 / Amount単位: %@", hz, 1 / hz, parameter.lfoAmountUnit)
            + (hz >= 15 ? "\n30fpsでは周期の形状を完全に再現できません。" : "")
            + (model.amount == 0 ? "\nAmountを増やすと基準値から振動します。" : "")
    }
    private func write(_ value: Double, number: Number, model: inout LFOSettings) {
        model[keyPath: number.key] = number == .phase ? value - floor(value / 360) * 360 : value
    }
    private func commit(_ value: Double, number: Number) {
        guard editable, clip?.activeLFO(parameter) != nil, value.isFinite else { return }
        var model = self.model; write(value, number: number, model: &model)
        guard model.isValid(for: parameter) else { NSSound.beep(); load(clip, editable: editable); return }
        onCommit?(parameter, .lfo, model)
    }
    @objc private func confirmNumber(_ field: DragValueField) {
        guard let number = fields.first(where: { $0.value === field })?.key,
              let value = Double(field.stringValue), value.isFinite else { load(clip, editable: editable); NSSound.beep(); return }
        commit(value, number: number)
    }
    func controlTextDidEndEditing(_ obj: Notification) { if let field = obj.object as? DragValueField { confirmNumber(field) } }
    @objc private func changeOption(_ control: NSControl) {
        guard editable else { return }
        if control === picker {
            guard parameters.indices.contains(picker.indexOfSelectedItem) else { return }
            select(parameters[picker.indexOfSelectedItem]); return
        }
        if control === mode { onCommit?(parameter, mode.indexOfSelectedItem == 1 ? .lfo : .keys, nil); return }
        var model = self.model
        if control === reset { model = LFOSettings() }
        else {
            model.timebase = timebase.indexOfSelectedItem == 0 ? .hertz : .beats
            model.beatsPerCycle = LFOSettings.BeatPeriod.choices[period.indexOfSelectedItem].period
            model.phaseOrigin = origin.indexOfSelectedItem == 0 ? .song : .clip
            model.bipolar = bipolar.state == .on
        }
        onCommit?(parameter, .lfo, model)
    }
}

@MainActor
final class LFOWaveformView: NSView {
    var model = LFOSettings() { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        let rect = bounds.insetBy(dx: 8, dy: 8)
        let zero = model.bipolar ? rect.midY : rect.minY
        let baseline = NSBezierPath(); baseline.move(to: .init(x: rect.minX, y: zero)); baseline.line(to: .init(x: rect.maxX, y: zero))
        NSColor.secondaryLabelColor.setStroke(); baseline.stroke()
        var wave = model; wave.timebase = .hertz; wave.frequencyHz = 1; wave.phaseOrigin = .clip; wave.clockOffsetSeconds = 0
        let samples = LFOEvaluator.samples(from: 0, through: 1, pixels: max(1, Int(rect.width)), clipStart: 0, settings: wave, scene: SceneSettings())
        let path = NSBezierPath()
        for (index, sample) in samples.enumerated() {
            let y = model.bipolar ? (sample.1 + 1) / 2 : sample.1
            let point = NSPoint(x: rect.minX + rect.width * sample.0, y: rect.minY + rect.height * y)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.systemCyan.setStroke(); path.lineWidth = 1.5; path.stroke()
    }
}
