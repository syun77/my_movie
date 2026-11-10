import AppKit

@MainActor
final class PresetMenu<Settings: PresetSettings>: NSObject, NSMenuDelegate {
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    private let store: PresetStore<Settings>
    private let finishEditing: () -> Bool
    private let current: () -> Settings?
    private let apply: (Settings) -> Void
    private var selectedName: String?

    init(store: PresetStore<Settings> = PresetStore(), finishEditing: @escaping () -> Bool,
         current: @escaping () -> Settings?,
         apply: @escaping (Settings) -> Void) {
        self.store = store
        self.finishEditing = finishEditing
        self.current = current
        self.apply = apply
        super.init()
        button.addItem(withTitle: "プリセット")
        button.setAccessibilityLabel("プリセット")
        if let menu = button.menu {
            menu.delegate = self
            menu.autoenablesItems = false
            rebuildMenu(menu, presets: [], emptyTitle: "保存済みプリセットなし")
        }
    }

    func clearSelection() { selectedName = nil }

    func menuNeedsUpdate(_ menu: NSMenu) {
        do {
            rebuildMenu(menu, presets: try store.load(), emptyTitle: "保存済みプリセットなし")
        } catch {
            rebuildMenu(menu, presets: [], emptyTitle: "プリセットを読み込めません")
        }
    }

    private func rebuildMenu(_ menu: NSMenu, presets: [NamedPreset<Settings>], emptyTitle: String) {
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        menu.addItem(makeItem("現在の設定を保存…", action: #selector(savePreset)))
        let selected = presets.first { $0.name == selectedName }
        let overwriteTitle = selected.map { "「\($0.name)」を上書き" } ?? "選択中のプリセットを上書き"
        let overwrite = makeItem(overwriteTitle, action: #selector(overwritePreset(_:)))
        overwrite.representedObject = selected?.name
        overwrite.isEnabled = selected != nil
        menu.addItem(overwrite)
        menu.addItem(.separator())
        if presets.isEmpty {
            let item = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for preset in presets {
            let item = makeItem(preset.name, action: #selector(applyPreset(_:)))
            item.representedObject = preset
            item.state = preset.name == selectedName ? .on : .off
            menu.addItem(item)
        }
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func savePreset() {
        guard button.isEnabled, let window = button.window, finishEditing(), let settings = current() else { return }
        let alert = NSAlert()
        alert.messageText = "プリセットを保存"
        alert.informativeText = "別のプロジェクトでも使えるように、名前を付けて保存します。"
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        name.placeholderString = "プリセット名"
        name.setAccessibilityLabel("プリセット名")
        alert.accessoryView = name
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                self.selectedName = try self.store.save(name: name.stringValue, settings: settings)
            } catch {
                self.showError(error)
            }
        }
    }

    @objc private func overwritePreset(_ sender: NSMenuItem) {
        guard button.isEnabled, let name = sender.representedObject as? String, name == selectedName,
              finishEditing(), let settings = current() else { return }
        do {
            try store.overwrite(name: name, settings: settings)
        } catch {
            showError(error)
        }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard button.isEnabled, let preset = sender.representedObject as? NamedPreset<Settings>, finishEditing() else { return }
        apply(preset.settings)
        selectedName = preset.name
    }

    private func showError(_ error: Error) {
        guard let window = button.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
