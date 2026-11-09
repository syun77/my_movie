import AppKit

@MainActor
final class DragValueField: NSTextField {
    var onDragStart: (() -> Bool)?
    var onDragChange: ((Double) -> Void)?
    var onDragEnd: (() -> Void)?
    var onReset: (() -> Void)?

    private var mouseStartX: Double?
    private var draggingValue = false

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled, currentEditor() == nil { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        cancelTracking()
        if event.clickCount >= 2 {
            selectText(nil)
        } else if window?.makeFirstResponder(nil) != false {
            mouseStartX = event.locationInWindow.x
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseStartX else { return }
        let distance = event.locationInWindow.x - start
        if !draggingValue {
            guard abs(distance) >= 3 else { return }
            guard onDragStart?() == true else { cancelTracking(); return }
            draggingValue = true
        }
        onDragChange?(distance)
    }

    override func mouseUp(with event: NSEvent) {
        if draggingValue {
            mouseDragged(with: event)
            cancelTracking()
            onDragEnd?()
        } else {
            cancelTracking()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2, resetValue() { return }
        super.otherMouseDown(with: event)
    }

    @discardableResult
    func resetValue() -> Bool {
        guard isEnabled, let onReset, window?.makeFirstResponder(nil) != false else { return false }
        onReset()
        return true
    }

    func cancelTracking() {
        mouseStartX = nil
        draggingValue = false
    }
}
