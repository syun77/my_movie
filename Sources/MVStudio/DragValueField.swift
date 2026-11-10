import AppKit

@MainActor
final class DragValueField: NSTextField {
    var onDragStart: (() -> Bool)?
    var onDragChange: ((Double) -> Void)?
    var onDragEnd: (() -> Void)?
    var onReset: (() -> Void)?

    private var mouseStartX: Double?
    private var draggingValue = false
    private var cancelNumber: (() -> Bool)?

    static let numberEditingHint = "左右ドラッグで調整、ダブルクリックで入力、ホイールクリックで初期値"

    static func fields(in view: NSView) -> [DragValueField] {
        if let field = view as? DragValueField { return [field] }
        return view.subviews.flatMap { fields(in: $0) }
    }

    func bindNumber(step: Double = 1, current: @escaping () -> Double?, initial: @escaping () -> Double?,
                    normalize: @escaping (Double) -> Double = { $0 },
                    preview: @escaping (Double?) -> Void = { _ in }, commit: @escaping (Double) -> Void) {
        toolTip = Self.numberEditingHint
        var drag: (original: Double, text: String, value: Double)?
        onDragStart = { [weak self] in
            guard let self, let value = current() else { return false }
            drag = (value, self.stringValue, value)
            return true
        }
        onDragChange = { [weak self] distance in
            guard let self, let original = drag?.original else { return }
            let value = normalize(original + distance.rounded() * step)
            drag?.value = value
            self.doubleValue = value
            preview(value)
        }
        onDragEnd = { [weak self] in
            guard let self, let finished = drag else { return }
            drag = nil
            preview(nil)
            if finished.value == finished.original { self.stringValue = finished.text }
            else { commit(finished.value) }
        }
        onReset = { [weak self] in
            guard let self else { return }
            self.cancelNumberDrag()
            guard let value = initial(), value != current() else { return }
            self.doubleValue = value
            commit(value)
        }
        cancelNumber = { [weak self] in
            guard let self, let original = drag else { return false }
            drag = nil
            self.stringValue = original.text
            preview(nil)
            return true
        }
    }

    func bindClipTime(isStart: Bool, interval: @escaping () -> (start: Double, end: Double)?,
                      duration: @escaping () -> Double, commit: @escaping () -> Void) {
        bindNumber(step: 0.01, current: { interval().map { isStart ? $0.start : $0.end } },
                   initial: { interval().map { isStart ? 0 : min(duration(), $0.start + 2) } },
                   normalize: { min(duration(), max(0, $0)) }, commit: { _ in commit() })
    }

    @discardableResult
    func cancelNumberDrag() -> Bool {
        guard cancelNumber != nil else { return false }
        cancelTracking()
        return cancelNumber?() ?? false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled, currentEditor() == nil { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if !cancelNumberDrag() { cancelTracking() }
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
