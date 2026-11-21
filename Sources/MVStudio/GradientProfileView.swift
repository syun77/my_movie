import AppKit

@MainActor
final class GradientProfileView: NSView {
    var gradient = ImageEffects.GradientBackground() { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 112) }

    override func draw(_ dirtyRect: NSRect) {
        let graph = NSRect(x: 30, y: 35, width: bounds.width - 38, height: bounds.height - 52)
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(rect: graph).fill()
        NSColor.separatorColor.setStroke(); NSBezierPath(rect: graph).stroke()
        let path = NSBezierPath()
        for i in 0...256 {
            let u = Double(i) / 256
            let p = NSPoint(x: graph.minX + u * graph.width, y: graph.minY + gradient.mixture(atFraction: u) * graph.height)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        NSColor.systemCyan.setStroke(); path.lineWidth = 1.5; path.stroke()
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        func srgb(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
        for i in 0..<256 {
            let t = gradient.mixture(atFraction: (Double(i) + 0.5) / 256)
            func channel(_ a: Double, _ b: Double) -> Double { srgb(linear(a) * (1-t) + linear(b) * t) }
            NSColor(srgbRed: channel(gradient.colorA.red, gradient.colorB.red),
                    green: channel(gradient.colorA.green, gradient.colorB.green),
                    blue: channel(gradient.colorA.blue, gradient.colorB.blue), alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: graph.minX + Double(i) / 256 * graph.width, y: 15,
                                     width: graph.width / 256 + 0.5, height: 12)).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        ("B 100%" as NSString).draw(at: NSPoint(x: 0, y: graph.maxY + 2), withAttributes: attributes)
        ("0%" as NSString).draw(at: NSPoint(x: 4, y: graph.minY), withAttributes: attributes)
        ("距離 0%" as NSString).draw(at: NSPoint(x: graph.minX, y: 0), withAttributes: attributes)
        ("100%" as NSString).draw(at: NSPoint(x: graph.maxX - 28, y: 0), withAttributes: attributes)
    }
}
