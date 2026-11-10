import AppKit

@MainActor
final class SpectrumEditor: NSViewController, NSTextFieldDelegate {
    var onChange: ((SpectrumSettings) -> Void)?
    var onLayoutPreview: ((SpectrumLayout?) -> Void)?
    var onEndTextEditing: (() -> Void)?
    private let shown = NSButton(checkboxWithTitle: "スペクトラムを表示", target: nil, action: nil)
    private let shape = NSPopUpButton()
    private let color = NSColorWell()
    private let resolution = NSPopUpButton()
    private lazy var presets = PresetMenu<SpectrumSettings>(
        finishEditing: { [weak self] in self?.finishEditing() ?? false },
        current: { [weak self] in self?.currentSettings },
        apply: { [weak self] in self?.applyPreset($0) }
    )

    private var fields: [SpectrumLayout.Field: DragValueField] = [:]
    private var layout = SpectrumLayout()

    override func loadView() {
        shape.addItems(withTitles: SpectrumStyle.Shape.allCases.map(\.title))
        resolution.addItems(withTitles: SpectrumStyle.Resolution.allCases.map { "\($0.rawValue) 帯域" })
        shape.identifier = NSUserInterfaceItemIdentifier("spectrum.shape")
        resolution.identifier = NSUserInterfaceItemIdentifier("spectrum.resolution")
        color.identifier = NSUserInterfaceItemIdentifier("spectrum.color")
        color.widthAnchor.constraint(equalToConstant: 48).isActive = true
        for control in [shown, shape, color, resolution] as [NSControl] {
            control.target = self
            control.action = #selector(changeSettings)
        }

        presets.button.identifier = NSUserInterfaceItemIdentifier("spectrum.presets")
        let root = NSStackView(views: [
            row([shown, presets.button]),
            row([label("表示形式"), shape, label("色", width: 22), color]),
            row([label("分解度"), resolution]),
            row([label("サイズ"), label("幅", width: 20), numberField(.width, title: "幅"),
                 label("高さ", width: 28), numberField(.height, title: "高さ")]),
            row([label("位置"), label("X", width: 20), numberField(.x, title: "X"),
                 label("Y", width: 28), numberField(.y, title: "Y")]),
            NSTextField(labelWithString: "サイズと位置は1080p基準のpx。原点は映像の左上。"),
            row([label("バーの余白"), numberField(.barGap, title: "バーの余白"), NSTextField(labelWithString: "%")])
        ])
        shape.setAccessibilityLabel("表示形式")
        color.setAccessibilityLabel("色")
        resolution.setAccessibilityLabel("分解度")
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        view = root
        fields[.barGap]?.toolTip = "中心間隔に対する余白の割合。\(DragValueField.numberEditingHint)"
        load(SceneSettings())
    }

    private func label(_ title: String, width: CGFloat = 72) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func numberField(_ parameter: SpectrumLayout.Field, title: String) -> DragValueField {
        let field = DragValueField(frame: .zero)
        field.identifier = NSUserInterfaceItemIdentifier("spectrum.\(parameter)")
        field.setAccessibilityLabel(title)
        field.alignment = .right
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let keyPath = parameter.keyPath
        let range = parameter.range
        field.bindNumber(current: { [weak self] in self.map { Double($0.layout[keyPath: keyPath]) } },
                         initial: { Double(SpectrumLayout()[keyPath: keyPath]) },
                         normalize: { min(Double(range.upperBound), max(Double(range.lowerBound), $0)) },
                         preview: { [weak self] value in
            guard let self else { return }
            self.onLayoutPreview?(value.map { self.layout(updating: parameter, to: Int($0)) })
        }, commit: { [weak self] value in self?.commitLayoutValue(Int(value), for: parameter) })
        fields[parameter] = field
        return field
    }

    func clearPresetSelection() { presets.clearSelection() }

    func load(_ settings: SceneSettings) {
        _ = view
        updateControls(SpectrumSettings(shown: settings.spectrum, style: settings.spectrumStyle))
    }

    private func updateControls(_ settings: SpectrumSettings) {
        shown.state = settings.shown ? .on : .off
        shape.selectItem(at: SpectrumStyle.Shape.allCases.firstIndex(of: settings.style.shape)!)
        color.color = settings.style.color.nsColor
        resolution.selectItem(at: SpectrumStyle.Resolution.allCases.firstIndex(of: settings.style.resolution)!)
        layout = settings.style.layout
        for (parameter, field) in fields {
            field.integerValue = layout[keyPath: parameter.keyPath]
        }
        updateGapAvailability()
    }

    func setAvailable(_ value: Bool, hasAudio: Bool) {
        _ = view
        for control in [shown, shape, color, resolution] as [NSControl] { control.isEnabled = value }
        presets.button.isEnabled = value && hasAudio
        for field in fields.values { field.isEnabled = value }
        updateGapAvailability()
        if !value { color.deactivate() }
    }

    func endColorEditing() { color.deactivate() }

    private var selectedShape: SpectrumStyle.Shape { SpectrumStyle.Shape.allCases[shape.indexOfSelectedItem] }

    private func updateGapAvailability() {
        fields[.barGap]?.isEnabled = shape.isEnabled && selectedShape == .bars
    }

    func finishEditing() -> Bool {
        view.window?.makeFirstResponder(nil) ?? true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let parameter = fields.first(where: { $0.value === field })?.key else { return }
        let value = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? layout[keyPath: parameter.keyPath]
        commitLayoutValue(value, for: parameter)
        onEndTextEditing?()
    }

    private func layout(updating parameter: SpectrumLayout.Field, to value: Int) -> SpectrumLayout {
        var result = layout
        let range = parameter.range
        result[keyPath: parameter.keyPath] = min(range.upperBound, max(range.lowerBound, value))
        return result
    }

    private func commitLayoutValue(_ value: Int, for parameter: SpectrumLayout.Field) {
        layout = layout(updating: parameter, to: value)
        fields[parameter]?.integerValue = layout[keyPath: parameter.keyPath]
        changeSettings()
    }

    private var currentSettings: SpectrumSettings {
        let style = SpectrumStyle(shape: selectedShape, color: RGBColor(color.color),
                                  resolution: SpectrumStyle.Resolution.allCases[resolution.indexOfSelectedItem],
                                  layout: layout)
        return SpectrumSettings(shown: shown.state == .on, style: style)
    }

    private func applyPreset(_ settings: SpectrumSettings) {
        endColorEditing()
        updateControls(settings)
        onChange?(settings)
    }

    @objc private func changeSettings() {
        updateGapAvailability()
        onChange?(currentSettings)
    }
}
