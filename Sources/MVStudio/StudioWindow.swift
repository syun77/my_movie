import AppKit

final class StudioWindow: NSWindow {
    var onBeginInteraction: (() -> Void)?
    var onEndInteraction: (() -> Void)?
    var onHistoryAction: ((Bool) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.charactersIgnoringModifiers?.lowercased() == "z", flags == .command || flags == [.command, .shift], onHistoryAction != nil {
            onHistoryAction?(flags.contains(.shift)); return true
        }
        return super.performKeyEquivalent(with: event)
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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onBeginInteraction?() }
        defer { if event.type == .leftMouseDown || event.type == .leftMouseUp { onEndInteraction?() } }
        guard attachedSheet == nil, NSApp.modalWindow == nil else {
            super.sendEvent(event)
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
