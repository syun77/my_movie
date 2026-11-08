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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onBeginInteraction?() }
        defer { if event.type == .leftMouseDown || event.type == .leftMouseUp { onEndInteraction?() } }
        guard event.type == .keyDown, attachedSheet == nil, NSApp.modalWindow == nil else {
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
        if event.keyCode == 53, isTyping {
            text?.unmarkText()
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
