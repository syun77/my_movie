import AppKit

@MainActor
final class EffectChainList: NSView {
    var nodes: [EffectNode] = [] {
        didSet {
            if nodes != oldValue { cancelDrag() }
            height.constant = Double(nodes.count) * rowHeight
            needsDisplay = true
        }
    }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var detailsOpen = true
    var editable = false {
        didSet {
            if !editable { cancelDrag() }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onSelect: ((UUID) -> Void)?
    var onToggle: ((UUID) -> Void)?
    var onMove: ((UUID, Int, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var menuForNode: ((UUID) -> NSMenu)?
    private let rowHeight = 28.0
    private let dragThreshold = 5.0
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    private struct Drag {
        let id: UUID
        let original: Int
        let initial: NSPoint
        var point: NSPoint
        var target: Int
        var active = false
    }
    struct DragPresentation {
        let id: UUID
        let sourceRect: NSRect
        let floatingRect: NSRect
        let insertionY: Double?
    }
    private var drag: Drag?
    var dragPresentation: DragPresentation? {
        guard let drag, drag.active else { return nil }
        let source = rowRect(drag.original)
        let floating = NSRect(x: source.minX, y: drag.point.y - (drag.initial.y - source.minY), width: source.width, height: source.height)
        let boundary = drag.target > drag.original ? drag.target + 1 : drag.target
        return DragPresentation(id: drag.id, sourceRect: source, floatingRect: floating,
                                insertionY: visibleRect.contains(drag.point) ? Double(boundary) * rowHeight : nil)
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        height.isActive = true
        identifier = NSUserInterfaceItemIdentifier("visuals.effects.chain")
        setAccessibilityLabel("演出チェーン。上から下へ適用")
    }
    required init?(coder: NSCoder) { nil }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: bounds.minX, y: Double(index) * rowHeight, width: bounds.width, height: rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: visibleRect).addClip()
        let presentation = dragPresentation
        for (index, node) in nodes.enumerated() {
            drawRow(node, in: rowRect(index), opacity: presentation?.id == node.id ? 0.3 : 1)
        }
        guard let presentation, let node = nodes.first(where: { $0.id == presentation.id }) else { return }
        drawRow(node, in: presentation.floatingRect, opacity: 0.85, floating: true)
        if let y = presentation.insertionY {
            NSColor.systemYellow.setFill()
            NSRect(x: bounds.minX, y: min(y, bounds.maxY - 2), width: bounds.width, height: 2).fill()
        }
    }

    private func drawRow(_ node: EffectNode, in rect: NSRect, opacity: Double, floating: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if floating {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if selectedID == node.id {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
            rect.fill()
        }
        let color = node.isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]
        for (text, x) in [("⠿", 4.0), (node.isEnabled ? "☑" : "☐", 29.0), (selectedID == node.id && detailsOpen ? "▾" : "▸", 52.0)] {
            (text as NSString).draw(at: NSPoint(x: rect.minX + x, y: rect.minY + 5), withAttributes: attributes)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var titleAttributes = attributes
        titleAttributes[.paragraphStyle] = paragraph
        let title = node.kind.title + (node.isEnabled ? "" : "（無効）")
        (title as NSString).draw(in: NSRect(x: rect.minX + 68, y: rect.minY + 5, width: max(0, rect.width - 100), height: rowHeight - 5), withAttributes: titleAttributes)
        ("⋯" as NSString).draw(at: NSPoint(x: rect.maxX - 24, y: rect.minY + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
        if floating {
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).stroke()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(floor(point.y / rowHeight))
        return visibleRect.contains(point) && nodes.indices.contains(index) ? index : nil
    }
    private func destination(at point: NSPoint, original: Int) -> Int {
        let boundary = min(nodes.count, max(0, Int((point.y / rowHeight).rounded())))
        return min(nodes.count - 1, boundary > original ? boundary - 1 : boundary)
    }
    override func mouseDown(with event: NSEvent) {
        guard editable, let index = index(at: event), window?.makeFirstResponder(self) != false else { return }
        let node = nodes[index]
        let point = convert(event.locationInWindow, from: nil)
        if point.x < bounds.minX + 24 {
            drag = Drag(id: node.id, original: index, initial: point, point: point, target: index)
        } else if point.x < bounds.minX + 50 { onToggle?(node.id) }
        else if point.x > bounds.maxX - 28 { showMenu(node.id, event: event) }
        else { onSelect?(node.id) }
    }
    private func updateDrag(at point: NSPoint) {
        guard var value = drag else { return }
        value.point = point
        if !value.active {
            guard hypot(point.x - value.initial.x, point.y - value.initial.y) >= dragThreshold else { drag = value; return }
            value.active = true
        }
        let inside = visibleRect.contains(point)
        let target = inside ? destination(at: point, original: value.original) : value.target
        let changed = target != value.target
        value.target = target
        drag = value
        needsDisplay = true
        (inside ? NSCursor.closedHand : NSCursor.operationNotAllowed).set()
        if changed { onMove?(value.id, target, true) }
    }
    override func mouseDragged(with event: NSEvent) {
        updateDrag(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        guard let value = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        finishDrag()
        guard value.active else { return }
        let target = destination(at: point, original: value.original)
        if visibleRect.contains(point) && target != value.original { onMove?(value.id, target, false) }
        else { onCancel?() }
    }
    private func finishDrag() {
        drag = nil
        needsDisplay = true
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
    }
    override func cancelOperation(_ sender: Any?) { _ = cancelDrag() }
    @discardableResult func cancelDrag() -> Bool {
        guard let value = drag else { return false }
        finishDrag()
        if value.active { onCancel?() }
        return true
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func resetCursorRects() {
        guard editable else { return }
        for index in nodes.indices {
            let handle = NSRect(x: bounds.minX, y: rowRect(index).minY, width: 24, height: rowHeight).intersection(visibleRect)
            if !handle.isEmpty { addCursorRect(handle, cursor: .openHand) }
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard drag == nil, editable, let index = index(at: event) else { return }
        showMenu(nodes[index].id, event: event)
    }
    private func showMenu(_ id: UUID, event: NSEvent) {
        guard let menu = menuForNode?(id) else { return }
        onSelect?(id)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

@MainActor
final class EffectMenuItem: NSMenuItem {
    private let perform: () -> Void
    init(_ title: String, enabled: Bool = true, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self; isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { perform() }
}
