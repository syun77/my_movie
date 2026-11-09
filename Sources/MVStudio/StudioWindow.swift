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
    var onResetEditingValue: ((NSPoint) -> Bool)?
    var onEscapeText: ((NSTextView) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onBeginInteraction?() }
        defer { if event.type == .leftMouseDown || event.type == .leftMouseUp { onEndInteraction?() } }
        guard attachedSheet == nil, NSApp.modalWindow == nil else {
            super.sendEvent(event)
            return
        }
        if event.type == .otherMouseDown, event.buttonNumber == 2,
           onResetEditingValue?(event.locationInWindow) == true { return }
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
        if event.keyCode == 53, onEscapeInteraction?() == true { return }
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
