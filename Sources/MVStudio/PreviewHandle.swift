import AppKit

/// Model coordinates are converted to the top-left-origin 1080p canvas here.
struct PreviewHandleCoordinates {
    var centered = false
    static func movieRect(in bounds: CGRect) -> CGRect {
        let fit = min(bounds.width / 1920, bounds.height / 1080)
        let size = CGSize(width: 1920 * fit, height: 1080 * fit)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    func canvas(_ value: CGPoint) -> CGPoint {
        centered ? CGPoint(x: 960 + value.x, y: 540 - value.y) : value
    }
    func model(_ point: CGPoint) -> CGPoint {
        centered ? CGPoint(x: point.x - 960, y: 540 - point.y) : point
    }
    func view(_ value: CGPoint, in rect: CGRect) -> CGPoint {
        let point = canvas(value)
        return CGPoint(x: rect.minX + point.x * rect.width / 1920,
                       y: rect.minY + point.y * rect.height / 1080)
    }
    func translated(_ value: CGPoint, by delta: CGPoint, in rect: CGRect) -> CGPoint {
        let origin = canvas(value)
        return model(CGPoint(x: origin.x + delta.x * 1920 / rect.width,
                             y: origin.y + delta.y * 1080 / rect.height))
    }
}

@MainActor
struct PreviewHandleTarget {
    let id: String
    let title: String
    var coordinates = PreviewHandleCoordinates()
    let isValid: () -> Bool
    let isVisible: () -> Bool
    let position: () -> CGPoint
    var evaluatedPosition: (() -> CGPoint)?
    let begin: () -> PreviewHandleEdit?
}

@MainActor
struct PreviewHandleEdit {
    let update: (CGPoint) -> Void
    let finish: (Bool) -> Void
}

@MainActor
final class PreviewHandleLabel: NSTextField {
    weak var valueField: DragValueField?
    convenience init(_ title: String, field: DragValueField) {
        self.init(labelWithString: title)
        valueField = field
    }
}

@MainActor
final class PreviewHandleView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var isPlaying = false { didSet { if isPlaying { cancelDrag() }; needsDisplay = true } }
    var canEdit = true { didSet { if !canEdit { clear() } } }
    private(set) var target: PreviewHandleTarget?
    private var edit: PreviewHandleEdit?
    private var startMouse = CGPoint.zero
    private var startValue = CGPoint.zero
    private var dragRect = CGRect.zero
    private var axis: Bool?
    private var hovering = false
    private var tracking: NSTrackingArea?
    var isDragging: Bool { edit != nil }
    var movieRect: CGRect { PreviewHandleCoordinates.movieRect(in: bounds) }

    func activate(_ value: PreviewHandleTarget?) {
        guard value?.id != target?.id else { refresh(); return }
        clear()
        target = value
        refresh()
    }
    func clear() {
        cancelDrag()
        target = nil
        updateFieldHighlights()
        needsDisplay = true
    }
    func refresh() {
        if let target, !target.isValid() { clear(); return }
        if edit != nil, !visible { cancelDrag() }
        updateFieldHighlights()
        needsDisplay = true
    }
    private func updateFieldHighlights() {
        guard let content = window?.contentView else { return }
        for field in DragValueField.fields(in: content) {
            field.showsPreviewHandle = target != nil && field.previewHandleProvider?()?.id == target?.id
        }
    }
    private var visible: Bool { canEdit && !isPlaying && target?.isVisible() == true && movieRect.width > 0 && movieRect.height > 0 }
    var handlePoint: CGPoint? {
        guard visible, let target else { return nil }
        let point = target.coordinates.view(target.position(), in: movieRect)
        let rect = movieRect.insetBy(dx: 14, dy: 14)
        return CGPoint(x: min(rect.maxX, max(rect.minX, point.x)), y: min(rect.maxY, max(rect.minY, point.y)))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local), let handle = handlePoint,
              hypot(handle.x - local.x, handle.y - local.y) <= 12 else { return nil }
        return self
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hovering = handlePoint.map { hypot($0.x - point.x, $0.y - point.y) <= 12 } ?? false
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = handlePoint, hypot(handle.x - point.x, handle.y - point.y) <= 12 else { clear(); return }
        guard window?.makeFirstResponder(nil) == true else { return }
        refresh()
        guard let target, target.isValid(), visible, let session = target.begin() else { return }
        edit = session; startMouse = point; startValue = target.position(); dragRect = movieRect; axis = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let edit, let target else { return }
        guard dragRect == movieRect, target.isValid(), visible else { cancelDrag(); return }
        let point = convert(event.locationInWindow, from: nil)
        var delta = CGPoint(x: point.x - startMouse.x, y: point.y - startMouse.y)
        if event.modifierFlags.contains(.shift) {
            if axis == nil, hypot(delta.x, delta.y) >= 3 { axis = abs(delta.x) >= abs(delta.y) }
            if let horizontal = axis { if horizontal { delta.y = 0 } else { delta.x = 0 } }
            else { delta = .zero }
        } else { axis = nil }
        edit.update(target.coordinates.translated(startValue, by: delta, in: dragRect))
        refresh()
    }
    override func mouseUp(with event: NSEvent) {
        guard edit != nil else { return }
        mouseDragged(with: event)
        let session = edit; edit = nil
        session?.finish(true)
        refresh()
    }
    @discardableResult
    func cancelDrag() -> Bool {
        guard let session = edit else { return false }
        edit = nil
        session.finish(false)
        needsDisplay = true
        return true
    }
    func escape() -> Bool {
        if cancelDrag() { return true }
        guard target != nil else { return false }
        clear(); return true
    }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { cancelDrag() }
        super.setFrameSize(newSize)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let target, let point = handlePoint else { return }
        let real = target.coordinates.view(target.position(), in: movieRect)
        let outside = !movieRect.contains(real)
        let color: NSColor = hovering || isDragging ? .systemYellow : NSColor(srgbRed: 0.65, green: 0.90, blue: 1, alpha: 1)
        var showsEvaluated = false
        if let evaluated = target.evaluatedPosition {
            let value = target.coordinates.view(evaluated(), in: movieRect)
            if hypot(value.x - real.x, value.y - real.y) > 1 {
                showsEvaluated = true
                let path = NSBezierPath(); path.move(to: real); path.line(to: value)
                path.setLineDash([3, 3], count: 2, phase: 0); color.withAlphaComponent(0.7).setStroke(); path.stroke()
                NSBezierPath(ovalIn: CGRect(x: value.x - 3, y: value.y - 3, width: 6, height: 6)).stroke()
            }
        }
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)).fill()
        color.setStroke()
        let cross = NSBezierPath(); cross.lineWidth = 2
        cross.move(to: CGPoint(x: point.x - 13, y: point.y)); cross.line(to: CGPoint(x: point.x + 13, y: point.y))
        cross.move(to: CGPoint(x: point.x, y: point.y - 13)); cross.line(to: CGPoint(x: point.x, y: point.y + 13)); cross.stroke()
        NSBezierPath(ovalIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)).stroke()
        if outside {
            let angle = atan2(real.y - point.y, real.x - point.x)
            let arrow = NSBezierPath()
            let tip = CGPoint(x: point.x + cos(angle) * 11, y: point.y + sin(angle) * 11)
            arrow.move(to: CGPoint(x: tip.x - cos(angle - 0.6) * 7, y: tip.y - sin(angle - 0.6) * 7))
            arrow.line(to: tip); arrow.line(to: CGPoint(x: tip.x - cos(angle + 0.6) * 7, y: tip.y - sin(angle + 0.6) * 7)); arrow.stroke()
        }
        let text = target.title + (outside ? " · 画面外" : "") + (showsEvaluated ? " · 基準位置を移動" : "")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .backgroundColor: NSColor.black.withAlphaComponent(0.75)]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: max(2, min(bounds.maxX - size.width - 2, point.x + 16)), y: max(2, min(bounds.maxY - size.height - 2, point.y + 15))), withAttributes: attributes)
    }
}
