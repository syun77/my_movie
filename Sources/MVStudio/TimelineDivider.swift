import AppKit

@MainActor
final class TimelineDivider: NSView {
    var timelineHeight: (() -> CGFloat?)?
    var onCommit: ((CGFloat) -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    private var dragged = false
    private var dragStart: (y: CGFloat, height: CGFloat)?

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("timeline.divider")
        toolTip = "上下にドラッグしてタイムラインの高さを調整"
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.30, green: 0.65, blue: 0.85, alpha: 0.65).setFill()
        NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()

        NSColor(srgbRed: 0.65, green: 0.90, blue: 1.00, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 14, y: bounds.midY - 1.5, width: 28, height: 3),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let height = timelineHeight?() else { return }
        dragged = false
        dragStart = (event.locationInWindow.y, height)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        dragged = true
        onDrag?(dragStart.height + event.locationInWindow.y - dragStart.y)
    }

    override func mouseUp(with event: NSEvent) {
        if dragged, let dragStart {
            mouseDragged(with: event)
            onCommit?(dragStart.height)
        }
        dragStart = nil
        dragged = false
    }
}
