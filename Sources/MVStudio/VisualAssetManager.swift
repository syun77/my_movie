import AppKit

@MainActor
final class VisualAssetManager: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var editor: VisualEditor?
    private let table = NSTableView()
    private let detail = NSTextField(wrappingLabelWithString: "素材を選択してください")
    private let message = NSTextField(labelWithString: "元の素材ファイルは削除しません")
    private var assets: [VisualAsset] = []
    private var buttons: [NSButton] = []

    init(editor: VisualEditor) {
        self.editor = editor
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.title = "素材管理（このプロジェクト）"
        super.init(window: panel)
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16); root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor), root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)])
        for (id, title, width) in [("image", "素材", 56.0), ("name", "ファイル名", 280.0), ("status", "状態", 150.0), ("uses", "使用数", 80.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 45
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(equalToConstant: 230).isActive = true
        detail.font = .systemFont(ofSize: 11); detail.maximumNumberOfLines = 6
        let add = NSButton(title: "素材を読み込む…", target: self, action: #selector(add))
        let replace = NSButton(title: "置き換え…", target: self, action: #selector(replace))
        let remove = NSButton(title: "素材を削除…", target: self, action: #selector(remove))
        let close = NSButton(title: "閉じる", target: self, action: #selector(closeSheet))
        let reloadButton = NSButton(title: "再読込", target: self, action: #selector(reloadSelected))
        buttons = [add, replace, reloadButton, remove, close]
        let toolbar = NSStackView(views: buttons); toolbar.spacing = 10
        message.font = .systemFont(ofSize: 11); message.lineBreakMode = .byTruncatingTail
        for child in [scroll, detail, message, toolbar] { root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reload() {
        let id = selected?.id
        assets = editor?.track.assets ?? []; table.reloadData()
        if let index = assets.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        updateDetail()
    }
    private var selected: VisualAsset? { assets.indices.contains(table.selectedRow) ? assets[table.selectedRow] : nil }
    func numberOfRows(in tableView: NSTableView) -> Int { assets.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let asset = assets[row], uses = editor?.track.uses(asset.id).count ?? 0
        switch tableColumn?.identifier.rawValue {
        case "image":
            let view = NSImageView(); view.image = editor?.thumbnails[asset.id]; view.imageScaling = .scaleProportionallyUpOrDown
            return view
        case "name": return NSTextField(labelWithString: (asset.kind.title + ": ") + asset.name)
        case "status": return NSTextField(labelWithString: editor?.missing.contains(asset.id) == true ? "見つからない/読込不能" : editor?.thumbnails[asset.id] == nil ? "確認中" : uses == 0 ? "未配置" : "読込済み")
        default: return NSTextField(labelWithString: "\(uses)配置")
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }
    private func updateDetail() {
        guard let asset = selected else { detail.stringValue = "素材を選択してください"; return }
        let url = editor?.projectURL.map { asset.reference.resolve(projectURL: $0).path } ?? asset.reference.path
        detail.stringValue = "\(asset.name)\n参照先: \(url)\n使用箇所:\n\(editor?.usageDescription(asset.id) ?? "")"
    }
    func setProcessing(_ value: Bool) { buttons.forEach { $0.isEnabled = !value }; table.isEnabled = !value }
    func showError(_ error: Error) { message.stringValue = error.localizedDescription }
    @objc private func add() { if let url = VisualEditor.chooseFile() { editor?.importFile(url) } }
    @objc private func replace() { guard let asset = selected, let url = VisualEditor.chooseFile() else { return }; editor?.importFile(url, replacingAsset: asset.id) }
    @objc private func reloadSelected() { if let asset = selected { editor?.reloadAsset(asset.id) } }
    @objc private func remove() {
        guard let asset = selected, let editor else { return }
        let uses = editor.track.uses(asset.id)
        if !uses.isEmpty {
            let alert = NSAlert(); alert.messageText = "使用中の素材を削除しますか？"
            alert.informativeText = "\(asset.name)の\(uses.count)件の配置も削除します。元ファイルは残します。\n" + editor.usageDescription(asset.id)
            alert.addButton(withTitle: "キャンセル"); alert.addButton(withTitle: "配置も削除して素材を削除")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        editor.deleteAsset(asset.id, includingPlacements: !uses.isEmpty)
    }
    @objc private func closeSheet() { guard let window, let parent = window.sheetParent else { return }; parent.endSheet(window) }
}
