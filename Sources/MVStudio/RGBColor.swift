import AppKit

struct RGBColor: Codable, Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = RGBColor(red: 0, green: 0, blue: 0)
    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent
    }
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}
