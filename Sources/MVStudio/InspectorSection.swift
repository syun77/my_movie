import AppKit

/// インスペクター共通のカテゴリ枠。内容の表示状態と編集操作は各エディターが管理する。
@MainActor
final class InspectorSection: NSStackView {
    nonisolated static let spacing: CGFloat = 8
    nonisolated static let labelWidth: CGFloat = 72
    nonisolated static let numberWidth: CGFloat = 86

    init(_ title: String?, id: String, rows: [NSView]) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("inspector.section." + id)
        orientation = .vertical
        alignment = .leading
        spacing = Self.spacing
        edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        if let title {
            let heading = NSTextField(labelWithString: title)
            heading.font = .boldSystemFont(ofSize: 12)
            addArrangedSubview(heading)
        }
        for row in rows {
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor, constant: -24).isActive = true
        }
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
        }
    }

    static func label(_ title: String, width: CGFloat = labelWidth) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.alignment = .centerY
        row.spacing = spacing
        return row
    }
}
