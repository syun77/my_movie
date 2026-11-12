import AppKit

@MainActor
final class AudioModulationEditor: NSStackView, NSTextFieldDelegate {
    var onCommit: ((ImageParameter, AudioModulation?) -> Void)?
    var onPreview: ((ImageParameter, AudioModulation?) -> Void)?
    var onSelect: ((ImageParameter) -> Void)?
    private let parameterPicker = NSPopUpButton()
    private let enabled = NSButton(checkboxWithTitle: "有効", target: nil, action: nil)
    private let source = NSPopUpButton()
    private let blend = NSPopUpButton()
    private let band = NSPopUpButton()
    private let add = NSButton(title: "追加", target: nil, action: nil)
    private let remove = NSButton(title: "削除", target: nil, action: nil)
    private let amount = DragValueField(frame: .zero)
    private let release = DragValueField(frame: .zero)
    private let denominator = DragValueField(frame: .zero)
    private let lower = DragValueField(frame: .zero)
    private let upper = DragValueField(frame: .zero)
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let unit = NSTextField(labelWithString: "")
    private let beatRow = NSStackView()
    private let shortcuts = NSStackView()
    private let bandRow = NSStackView()
    private let customRow = NSStackView()
    private var parameters: [ImageParameter] = []
    private var clip: VisualClip?
    private var editable = false
    private(set) var parameter: ImageParameter = .scale
    private var model: AudioModulation? { clip?.audioModulations[parameter] }
    private var controls: [NSControl] = []
    var settings = SceneSettings() { didSet { updateExplanation() } }
    var features: AudioFeatures? { didSet { updateExplanation() } }
    var analysisError: String? { didSet { updateExplanation() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical; alignment = .leading; spacing = 5
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views); row.spacing = 6; row.alignment = .centerY
            addArrangedSubview(row); return row
        }
        let title = NSTextField(labelWithString: "音楽同期")
        title.font = .boldSystemFont(ofSize: 12)
        _ = row([title, parameterPicker, add, remove])
        parameterPicker.widthAnchor.constraint(equalToConstant: 185).isActive = true
        parameterPicker.target = self; parameterPicker.action = #selector(selectParameter)
        add.target = self; add.action = #selector(addSetting)
        remove.target = self; remove.action = #selector(removeSetting)
        source.addItems(withTitles: AudioModulation.Source.allCases.map(\.title))
        band.addItems(withTitles: TransientBand.Kind.allCases.map(\.title))
        blend.addItems(withTitles: AudioModulation.Blend.allCases.map(\.title))
        for picker in [source, band, blend] { picker.target = self; picker.action = #selector(changeOption) }
        enabled.target = self; enabled.action = #selector(changeOption)
        _ = row([enabled, NSTextField(labelWithString: "入力"), source, blend])
        beatRow.orientation = .horizontal; beatRow.spacing = 6
        for view in [NSTextField(labelWithString: "音符分母"), denominator, NSTextField(labelWithString: "（1〜16）")] { beatRow.addArrangedSubview(view) }
        addArrangedSubview(beatRow)
        shortcuts.spacing = 4
        for value in [1, 2, 4, 8, 16] {
            let button = NSButton(title: value == 1 ? "全" : String(value), target: self, action: #selector(chooseNote(_:)))
            button.tag = value; shortcuts.addArrangedSubview(button)
        }
        addArrangedSubview(shortcuts)
        bandRow.spacing = 6
        bandRow.addArrangedSubview(NSTextField(labelWithString: "検出帯域")); bandRow.addArrangedSubview(band)
        addArrangedSubview(bandRow)
        customRow.spacing = 6
        for view in [NSTextField(labelWithString: "下限Hz"), lower, NSTextField(labelWithString: "上限Hz"), upper] { customRow.addArrangedSubview(view) }
        addArrangedSubview(customRow)
        _ = row([NSTextField(labelWithString: "変化量"), amount, unit, NSTextField(labelWithString: "戻り秒"), release])
        for label in [explanation, status] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; addArrangedSubview(label); label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        let definitions: [(DragValueField, String, Double, Double, ClosedRange<Double>)] = [
            (amount, "amount", 1, 0, -10000...10000), (release, "release", 0.01, 0.3, 0.03...2),
            (denominator, "denominator", 1, 4, 1...16), (lower, "lower", 1, 40, 20...20000), (upper, "upper", 1, 180, 20...20000)
        ]
        for (field, name, step, initial, range) in definitions {
            field.identifier = NSUserInterfaceItemIdentifier("audioModulation." + name)
            field.delegate = self; field.target = self; field.action = #selector(confirmNumber(_:))
            field.widthAnchor.constraint(equalToConstant: 92).isActive = true
            field.knobRange = range
            field.bindNumber(step: step, current: { [weak self, weak field] in
                guard let self, let field, let model = self.model else { return nil }
                return self.number(field, in: model)
            }, initial: { [weak self, weak field] in
                guard let self, field === self.amount else { return initial }
                return AudioModulation.initial(for: self.parameter).amount
            }, normalize: { min(range.upperBound, max(range.lowerBound, $0)) }, preview: { [weak self, weak field] value in
                guard let self, let field, var model = self.model else { return }
                if let value {
                    self.write(value, field: field, model: &model, reset: false)
                    guard model.isValid(for: self.parameter) else { return }
                    self.onPreview?(self.parameter, model)
                    if field === self.lower || field === self.upper { self.status.stringValue = "確定後に解析" }
                } else { self.onPreview?(self.parameter, nil) }
            }, commit: { [weak self, weak field] value in
                guard let self, let field else { return }
                self.commitNumber(value, field: field, reset: false)
            })
            field.onReset = { [weak self, weak field] in
                guard let self, let field else { return }
                field.cancelNumberDrag()
                let value = field === self.amount ? AudioModulation.initial(for: self.parameter).amount : initial
                self.commitNumber(value, field: field, reset: true)
            }
        }
        controls = [enabled, source, blend, band, amount, release, denominator, lower, upper] + shortcuts.arrangedSubviews.compactMap { $0 as? NSControl }
        parameterPicker.identifier = NSUserInterfaceItemIdentifier("audioModulation.parameter")
        source.identifier = NSUserInterfaceItemIdentifier("audioModulation.source")
        band.identifier = NSUserInterfaceItemIdentifier("audioModulation.band")
        blend.identifier = NSUserInterfaceItemIdentifier("audioModulation.blend")
        enabled.identifier = NSUserInterfaceItemIdentifier("audioModulation.enabled")
        load(nil, editable: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ clip: VisualClip?, editable: Bool) {
        self.clip = clip; self.editable = editable
        let available = ImageParameter.allCases.filter { $0.effect == nil || $0.effect?.read(clip?.effects ?? ImageEffects()) != nil }
        if parameters != available {
            parameters = available; parameterPicker.removeAllItems(); parameterPicker.addItems(withTitles: available.map(\.title))
        }
        if !parameters.contains(parameter) { parameter = .scale }
        parameterPicker.selectItem(withTitle: parameter.title)
        parameterPicker.isEnabled = editable && clip != nil
        add.isEnabled = editable && clip != nil && model == nil
        remove.isEnabled = editable && model != nil
        controls.forEach { $0.isEnabled = editable && model != nil }
        if let model {
            enabled.state = model.enabled ? .on : .off
            source.selectItem(withTitle: model.source.title); blend.selectItem(withTitle: model.blend.title)
            blend.item(at: 1)?.isEnabled = parameter.allowsRelativeModulation
            blend.autoenablesItems = false
            band.selectItem(at: TransientBand.Kind.allCases.firstIndex(of: model.transientBand.kind) ?? 0)
            for field in [amount, release, denominator, lower, upper] where field.currentEditor() == nil { field.doubleValue = number(field, in: model) }
            amount.knobRange = parameter.modulationRange(model.blend)
            unit.stringValue = model.blend == .relative ? "%" : parameter == .opacity ? "pt" : parameter.unit
        }
        let isBeat = model?.source == .beat
        beatRow.isHidden = !isBeat; shortcuts.isHidden = !isBeat
        bandRow.isHidden = model == nil || isBeat
        customRow.isHidden = model == nil || isBeat || model?.transientBand.kind != .custom
        updateExplanation()
    }
    func select(_ parameter: ImageParameter, notify: Bool = true) {
        cancelDrag(); self.parameter = parameter; load(clip, editable: editable)
        if notify { onSelect?(parameter) }
    }
    @discardableResult func cancelDrag() -> Bool {
        var cancelled = false
        for field in [amount, release, denominator, lower, upper] { cancelled = field.cancelNumberDrag() || cancelled }
        return cancelled
    }
    private func updateExplanation() {
        guard let model else { explanation.stringValue = "項目を選び「追加」で拍・トランジェントに同期します。"; status.stringValue = ""; return }
        if model.source == .beat {
            let n = model.beatNoteDenominator
            let period = BeatTiming.period(bpm: settings.bpm, denominator: n)
            let title = [1, 2, 4, 8, 16].contains(n) ? (n == 1 ? "全音符" : "\(n)分音符") : "全音符長の1/\(n)"
            explanation.stringValue = String(format: "%@・%.3g拍ごと・%.3f秒", title, 4 / Double(n), period)
            status.stringValue = model.releaseSeconds > period ? "次の発火までに戻り切りません。" : ""
        } else {
            explanation.stringValue = "選択帯域のアタックで発火します。同じ帯域の他の音にも反応します。"
            if let features {
                let bounds = model.transientBand.bounds(sampleRate: features.sampleRate)
                if bounds == nil { status.stringValue = "この音声には指定帯域がありません。" }
                else if let events = features.transientEvents[model.transientBand.key] {
                    status.stringValue = String(format: "実効 %.0f〜%.0fHz・検出 %d件", bounds!.lowerBound, bounds!.upperBound, events.count)
                } else { status.stringValue = analysisError ?? "解析中…" }
            } else { status.stringValue = "音声を読み込んでください。" }
        }
    }
    private func number(_ field: DragValueField, in model: AudioModulation) -> Double {
        if field === amount { return model.amount }
        if field === release { return model.releaseSeconds }
        if field === denominator { return Double(model.beatNoteDenominator) }
        return field === lower ? model.transientBand.lowerHz : model.transientBand.upperHz
    }
    private func write(_ value: Double, field: DragValueField, model: inout AudioModulation, reset: Bool) {
        if field === amount { model.amount = value }
        else if field === release { model.releaseSeconds = value }
        else if field === denominator { model.beatNoteDenominator = Int(value.rounded()) }
        else {
            if field === lower { model.transientBand.lowerHz = value.rounded() }
            else { model.transientBand.upperHz = value.rounded() }
            if reset, !model.transientBand.isValid {
                if field === lower && value == 40 { model.transientBand.upperHz = 180 }
                if field === upper && value == 180 { model.transientBand.lowerHz = 40 }
            }
        }
    }
    private func commitNumber(_ value: Double, field: DragValueField, reset: Bool) {
        guard editable, var model else { return }
        guard value.isFinite, field !== denominator || (1...16).contains(value) else {
            NSSound.beep(); load(clip, editable: editable); return
        }
        write(value, field: field, model: &model, reset: reset)
        if model.isValid(for: parameter) { onCommit?(parameter, model) }
        else { NSSound.beep(); load(clip, editable: editable) }
    }
    @objc private func confirmNumber(_ field: DragValueField) {
        guard let value = Double(field.stringValue), value.isFinite,
              field === amount || field === release || value.rounded() == value else { load(clip, editable: editable); NSSound.beep(); return }
        commitNumber(value, field: field, reset: false)
    }
    func controlTextDidEndEditing(_ obj: Notification) { if let field = obj.object as? DragValueField { confirmNumber(field) } }
    @objc private func selectParameter() {
        guard parameters.indices.contains(parameterPicker.indexOfSelectedItem) else { return }
        select(parameters[parameterPicker.indexOfSelectedItem])
    }
    @objc private func addSetting() { onCommit?(parameter, .initial(for: parameter)) }
    @objc private func removeSetting() { onCommit?(parameter, nil) }
    @objc private func chooseNote(_ button: NSButton) {
        guard var model else { return }; model.beatNoteDenominator = button.tag; onCommit?(parameter, model)
    }
    @objc private func changeOption() {
        guard var model else { return }
        model.enabled = enabled.state == .on
        model.source = AudioModulation.Source.allCases[source.indexOfSelectedItem]
        model.blend = AudioModulation.Blend.allCases[blend.indexOfSelectedItem]
        model.transientBand.kind = TransientBand.Kind.allCases[band.indexOfSelectedItem]
        let range = parameter.modulationRange(model.blend)
        model.amount = min(range.upperBound, max(range.lowerBound, model.amount))
        onCommit?(parameter, model)
    }
}
