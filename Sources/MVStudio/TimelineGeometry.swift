import Foundation

struct TimelineGeometry {
    let origin: Double
    let span: Double
    let width: Double
    static let inset = 14.0

    init(time: Double, duration: Double, span: Double, width: Double, manualOrigin: Double? = nil) {
        self.span = span.isFinite && span > 0 ? span : TimelineDisplaySettings.defaultSpan
        self.width = max(Self.inset * 2 + 1, width)
        origin = Self.clampOrigin(manualOrigin ?? time - self.span / 2, duration: duration, span: self.span)
    }
    static func clampOrigin(_ origin: Double, duration: Double, span: Double) -> Double {
        min(max(0, duration - span), max(0, origin))
    }
    var tickInterval: Double {
        let target = span / max(1, (width - Self.inset * 2) / 85)
        let magnitude = pow(10, floor(log10(target)))
        return ([1.0, 2, 5, 10].first { $0 * magnitude >= target } ?? 10) * magnitude
    }
    var pointsPerSecond: Double { (width - Self.inset * 2) / span }
    func x(at time: Double) -> Double { Self.inset + (time - origin) * pointsPerSecond }
    func time(at x: Double) -> Double { origin + (x - Self.inset) / pointsPerSecond }
    static func label(_ time: Double) -> String {
        let milliseconds = Int((max(0, time) * 1000).rounded())
        return String(format: "%02d:%02d.%03d", milliseconds / 60000, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}

enum TimelineDragPart { case move, start, end }
