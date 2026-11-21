import AppKit
import UniformTypeIdentifiers

@MainActor
final class ParticleAppearanceEditor: NSStackView {
    var onChange: ((ParticleAppearance) -> Void)?
    var onImport: ((URL) -> Void)?
    private let mode = NSPopUpButton()
    private let imageName = NSTextField(labelWithString: "画像未指定（既存の形状）")
    private let preview = ParticleImagePreview()
    private let choose = NSButton(title: "素材から選択…", target: nil, action: nil)
    private let read = NSButton(title: "画像を読み込む…", target: nil, action: nil)
    private let clear = NSButton(title: "解除", target: nil, action: nil)
    private let color = NSPopUpButton()
    private let blend = NSPopUpButton()
    private var imageSummary: NSView?
    private var imageDetails: [NSView] = []
    private var particleStyle = ParticleAppearance()
    private var assets: [VisualAsset] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 4
        mode.addItems(withTitles: ["標準", "画像"])
        color.addItems(withTitles: ["元画像", "演出色"])
        blend.addItems(withTitles: ["通常", "加算"])
        for control in [mode, color, blend] { control.target = self; control.action = #selector(change) }
        choose.target = self; choose.action = #selector(selectAsset)
        read.target = self; read.action = #selector(readImage)
        clear.target = self; clear.action = #selector(clearImage)
        preview.onDrop = { [weak self] in self?.onImport?($0) }
        preview.widthAnchor.constraint(equalToConstant: 64).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 48).isActive = true
        for views in [[NSTextField(labelWithString: "粒子の見た目"), mode], [preview, imageName], [choose, read, clear], [NSTextField(labelWithString: "色"), color, NSTextField(labelWithString: "合成"), blend]] {
            let row = NSStackView(views: views); row.spacing = 6; addArrangedSubview(row)
            if views.contains(where: { $0 === preview }) { imageSummary = row }
            if views.contains(where: { $0 === color }) { imageDetails.append(row) }
        }
        let note = NSTextField(wrappingLabelWithString: "透過画像を推奨。黒背景は透過されません。複数フレーム画像は先頭のみ使用します。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        addArrangedSubview(note); imageDetails.append(note)
    }
    required init?(coder: NSCoder) { fatalError() }

    func load(_ value: ParticleAppearance, assets: [VisualAsset], thumbnails: [UUID: NSImage], missing: Set<UUID>, editable: Bool) {
        particleStyle = value; self.assets = assets.filter { $0.kind == .still }
        mode.selectItem(at: value.usesImage ? 1 : 0)
        color.selectItem(at: value.colorMode == .original ? 0 : 1)
        blend.selectItem(at: value.blend == .normal ? 0 : 1)
        let asset = assets.first { $0.id == value.assetID }
        imageName.stringValue = asset.map { $0.name + (missing.contains($0.id) ? "（見つかりません）" : "") } ?? "画像未指定（既存の形状）"
        preview.image = value.assetID.flatMap { thumbnails[$0] }
        preview.editable = editable
        for control in [mode, color, blend, choose, read, clear] as [NSControl] { control.isEnabled = editable }
        imageSummary?.isHidden = value.assetID == nil
        imageDetails.forEach { $0.isHidden = !value.usesImage }
        clear.isHidden = value.assetID == nil
        clear.isEnabled = editable && value.assetID != nil
        color.isEnabled = editable && value.usesImage; blend.isEnabled = color.isEnabled
    }
    @objc private func change() {
        particleStyle.mode = mode.indexOfSelectedItem == 1 && particleStyle.assetID != nil ? .image : .standard
        particleStyle.colorMode = color.indexOfSelectedItem == 0 ? .original : .effect
        particleStyle.blend = blend.indexOfSelectedItem == 0 ? .normal : .additive
        onChange?(particleStyle)
    }
    @objc private func clearImage() { particleStyle.assetID = nil; particleStyle.mode = .standard; onChange?(particleStyle) }
    @objc private func selectAsset() {
        guard !assets.isEmpty else { return }
        let popup = NSPopUpButton(); popup.addItems(withTitles: assets.map(\.name))
        let alert = NSAlert(); alert.messageText = "粒子に使う画像"; alert.accessoryView = popup
        alert.addButton(withTitle: "選択"); alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        particleStyle.assetID = assets[popup.indexOfSelectedItem].id; particleStyle.mode = .image; onChange?(particleStyle)
    }
    @objc private func readImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.message = "透過画像を推奨。アニメーション画像は先頭フレームのみ使用します。"
        if panel.runModal() == .OK, let url = panel.url { onImport?(url) }
    }
}

@MainActor
private final class ParticleImagePreview: NSView {
    var onDrop: ((URL) -> Void)?
    var editable = false
    var image: NSImage? { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        for y in stride(from: 0, to: Int(bounds.height), by: 8) {
            for x in stride(from: 0, to: Int(bounds.width), by: 8) {
                ((x / 8 + y / 8) % 2 == 0 ? NSColor(white: 0.3, alpha: 1) : NSColor(white: 0.5, alpha: 1)).setFill()
                NSRect(x: x, y: y, width: 8, height: 8).fill()
            }
        }
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }
    private func url(_ sender: NSDraggingInfo) -> URL? {
        guard editable, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.count == 1,
              let type = UTType(filenameExtension: urls[0].pathExtension), type.conforms(to: .image) else { return nil }
        return urls[0]
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { url(sender) == nil ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { guard let url = url(sender) else { return false }; onDrop?(url); return true }
}
