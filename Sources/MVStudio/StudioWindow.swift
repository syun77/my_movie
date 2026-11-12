import AppKit

final class StudioWindow: NSWindow {
    weak var clipEditor: PlacementEditor?
    var onBeginInteraction: (() -> Void)?
    var onEndInteraction: (() -> Void)?
    var onHistoryAction: ((Bool) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.charactersIgnoringModifiers?.lowercased() == "z", flags == .command || flags == [.command, .shift], onHistoryAction != nil {
            onHistoryAction?(flags.contains(.shift)); return true
        }
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased(),
           let command = ClipEditCommand(rawValue: key), canEditClip(command) {
            if !event.isARepeat { clipEditor?.editClip(command, pasteboard: .general) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func canEditClip(_ command: ClipEditCommand) -> Bool {
        guard attachedSheet == nil, NSApp.modalWindow == nil, !(firstResponder is NSTextView) else { return false }
        return clipEditor?.canEditClip(command, pasteboard: .general) == true
    }

    private func editClip(_ command: ClipEditCommand) {
        guard canEditClip(command) else { return }
        clipEditor?.editClip(command, pasteboard: .general)
    }

    @objc func cut(_ sender: Any?) { editClip(.cut) }
    @objc func copy(_ sender: Any?) { editClip(.copy) }
    @objc func paste(_ sender: Any?) { editClip(.paste) }
    @objc func duplicateClip(_ sender: Any?) { editClip(.duplicate) }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(cut(_:)): return canEditClip(.cut)
        case #selector(copy(_:)): return canEditClip(.copy)
        case #selector(paste(_:)): return canEditClip(.paste)
        case #selector(duplicateClip(_:)): return canEditClip(.duplicate)
        default: return super.validateMenuItem(item)
        }
    }

    var onTogglePlayback: (() -> Void)?
    var onEscapeInteraction: (() -> Bool)?
    var onEscapeText: ((NSTextView) -> Bool)?

    @discardableResult
    func cancelNumberDrags() -> Bool {
        guard let contentView else { return false }
        return DragValueField.fields(in: contentView).contains { $0.cancelNumberDrag() }
    }

    private func resetEditingNumber(at location: NSPoint) -> Bool {
        guard let contentView, let field = DragValueField.fields(in: contentView).first(where: {
            $0.currentEditor() != nil && $0.bounds.contains($0.convert(location, from: nil))
        }) else { return false }
        return field.resetValue()
    }

    func editingAutomationField(for event: NSEvent) -> DragValueField? {
        guard event.type == .rightMouseDown, let contentView else { return nil }
        return DragValueField.fields(in: contentView).first {
            !$0.isHiddenOrHasHiddenAncestor && $0.currentEditor() != nil && $0.menu(for: event) != nil
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onBeginInteraction?() }
        defer { if event.type == .leftMouseDown || event.type == .leftMouseUp { onEndInteraction?() } }
        guard attachedSheet == nil, NSApp.modalWindow == nil else {
            super.sendEvent(event)
            return
        }
        if let field = editingAutomationField(for: event) {
            field.rightMouseDown(with: event)
            return
        }
        if event.type == .otherMouseDown, event.buttonNumber == 2,
           resetEditingNumber(at: event.locationInWindow) { return }
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let commandSpace = event.keyCode == 49 && modifiers == .command
        guard commandSpace || modifiers.intersection([.command, .control, .option]).isEmpty else {
            super.sendEvent(event)
            return
        }
        let text = firstResponder as? NSTextView
        let isTyping = text?.isEditable == true
        if event.keyCode == 53, cancelNumberDrags() || onEscapeInteraction?() == true { return }
        if event.keyCode == 53, isTyping, let text {
            if onEscapeText?(text) == true { return }
            text.unmarkText()
            makeFirstResponder(nil)
            return
        }
        if event.keyCode == 49, commandSpace || !isTyping {
            if !event.isARepeat { onTogglePlayback?() }
            return
        }
        super.sendEvent(event)
    }
}
