import AppKit

@MainActor
final class DragValueField: NSTextField {
    var onDragStart: (() -> Bool)?
    var onDragChange: ((Double) -> Void)?
    var onDragEnd: (() -> Void)?
    var onReset: (() -> Void)?
    var onCreateAutomation: (() -> Void)?
    var onRemoveAutomation: (() -> Void)?
    var hasAutomation = false { didSet { needsDisplay = true } }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard isEnabled, bounds.contains(point),
              onCreateAutomation != nil, onRemoveAutomation != nil else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: hasAutomation ? "オートメーションを削除" : "オートメーションを作成",
                               action: #selector(changeAutomation), keyEquivalent: "")
        item.target = self
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func changeAutomation() {
        guard isEnabled else { return }
        if hasAutomation { onRemoveAutomation?() } else { onCreateAutomation?() }
    }

    private var mouseStart: NSPoint?
    private var previousMouse: NSPoint?
    private var verticalDrag = false
    private var dragDistance = 0.0
    var knobRange: ClosedRange<Double>? { didSet { needsDisplay = true } }
    var knobInitialValue = 0.0
    private var knobStep = 1.0
    private var initialNumber: (() -> Double?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = KnobValueCell(textCell: "")
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 24, height: max(24, size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let center = NSPoint(x: 11, y: bounds.midY)
        let radius: CGFloat = 8
        let opacity: CGFloat = isEnabled ? 1 : 0.35
        NSColor.controlBackgroundColor.withAlphaComponent(opacity).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)).fill()
        let initialValue = initialNumber?() ?? knobInitialValue
        let value = Double(stringValue) ?? initialValue
        func fraction(_ value: Double) -> Double {
            if let range = knobRange, range.upperBound > range.lowerBound {
                return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
            }
            return 0.5 + atan((value - initialValue) / max(0.000001, knobStep * 50)) / .pi
        }
        func point(_ fraction: Double, radius: CGFloat) -> NSPoint {
            let angle = (225 - fraction * 270) * .pi / 180
            return NSPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius)
        }
        let track = NSBezierPath()
        for index in 0...60 {
            let p = point(Double(index) / 60, radius: radius)
            if index == 0 { track.move(to: p) } else { track.line(to: p) }
        }
        NSColor.separatorColor.withAlphaComponent(opacity).setStroke()
        track.lineWidth = 2; track.stroke()
        let indicator = NSBezierPath()
        indicator.move(to: center); indicator.line(to: point(fraction(value), radius: 6))
        NSColor(srgbRed: 0.65, green: 0.90, blue: 1.00, alpha: opacity).setStroke()
        indicator.lineWidth = 2; indicator.lineCapStyle = .round; indicator.stroke()
        if hasAutomation {
            NSColor(srgbRed: 0.30, green: 0.80, blue: 1.00, alpha: opacity).setFill()
            let y = isFlipped ? center.y - 12 : center.y + 4
            NSBezierPath(ovalIn: NSRect(x: 15, y: y, width: 8, height: 8)).fill()
        }
        let initial = point(fraction(initialValue), radius: 10)
        NSColor.secondaryLabelColor.withAlphaComponent(opacity).setFill()
        NSBezierPath(ovalIn: NSRect(x: initial.x - 1, y: initial.y - 1, width: 2, height: 2)).fill()
    }

    private var draggingValue = false
    private var cancelNumber: (() -> Bool)?

    static let numberEditingHint = "上下左右ドラッグで調整（右・上で増加）、Shiftで微調整、ダブルクリックで入力、ホイールクリックで初期値"

    static func fields(in view: NSView) -> [DragValueField] {
        if let field = view as? DragValueField { return [field] }
        return view.subviews.flatMap { fields(in: $0) }
    }

    func bindNumber(step: Double = 1, current: @escaping () -> Double?, initial: @escaping () -> Double?,
                    normalize: @escaping (Double) -> Double = { $0 },
                    preview: @escaping (Double?) -> Void = { _ in }, commit: @escaping (Double) -> Void) {
        toolTip = Self.numberEditingHint
        knobStep = step
        initialNumber = initial
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
        if isEnabled, currentEditor() == nil { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if !cancelNumberDrag() { cancelTracking() }
        if event.clickCount >= 2 {
            selectText(nil)
        } else if window?.makeFirstResponder(nil) != false {
            mouseStart = event.locationInWindow
            previousMouse = event.locationInWindow
            dragDistance = 0
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseStart, let previous = previousMouse else { return }
        let position = event.locationInWindow
        if !draggingValue {
            let dx = position.x - start.x, dy = position.y - start.y
            guard max(abs(dx), abs(dy)) >= 3 else { return }
            guard onDragStart?() == true else { cancelTracking(); return }
            verticalDrag = abs(dy) > abs(dx)
            draggingValue = true
        }
        let delta = verticalDrag ? position.y - previous.y : position.x - previous.x
        dragDistance += delta * (event.modifierFlags.contains(.shift) ? 0.1 : 1)
        previousMouse = position
        onDragChange?(dragDistance)
        needsDisplay = true
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
        mouseStart = nil
        previousMouse = nil
        needsDisplay = true
        draggingValue = false
    }
}

@MainActor
private final class KnobValueCell: NSTextFieldCell {
    private func textFrame(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 24, y: rect.minY, width: max(0, rect.width - 24), height: rect.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.draw(withFrame: textFrame(cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: textFrame(rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: textFrame(rect), in: controlView, editor: editor,
                     delegate: delegate, start: selStart, length: selLength)
    }
}
