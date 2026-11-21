import Foundation

extension ImageEffects {
    struct GradientBackground: Codable, Equatable, Sendable {
        enum Shape: String, Codable, CaseIterable, Sendable {
            case linear, radial
            var title: String { self == .linear ? "直線" : "円形" }
        }
        enum Pattern: String, Codable, CaseIterable, Sendable {
            case forward, mirrored
            var title: String { self == .forward ? "A→B" : "A→B→A" }
        }
        var isEnabled = true
        var colorA = RGBColor(red: 0, green: 0, blue: 0)
        var colorB = RGBColor(red: 1, green: 1, blue: 1)
        var shape = Shape.linear
        var pattern = Pattern.forward
        var x = 960.0
        var y = 540.0
        var position = 0.0
        var width = 1920.0
        var angle = 0.0
        var bias = 0.0
        var opacity = 100.0

        struct Field {
            let parameter: ImageParameter
            let title: String
            let unit: String
            let path: WritableKeyPath<GradientBackground, Double>
            let range: ClosedRange<Double>
        }
        static let fields: [Field] = [
            Field(parameter: .gradientX, title: "中心X", unit: "px", path: \.x, range: -7680...7680),
            Field(parameter: .gradientY, title: "中心Y", unit: "px", path: \.y, range: -7680...7680),
            Field(parameter: .gradientPosition, title: "位置", unit: "px", path: \.position, range: -7680...7680),
            Field(parameter: .gradientWidth, title: "変化幅", unit: "px", path: \.width, range: 1...15360),
            Field(parameter: .gradientAngle, title: "角度", unit: "°", path: \.angle, range: -3600...3600),
            Field(parameter: .gradientBias, title: "偏り", unit: "%", path: \.bias, range: -100...100),
            Field(parameter: .gradientOpacity, title: "不透明度", unit: "%", path: \.opacity, range: 0...100)
        ]
        static let fieldsByParameter = Dictionary(uniqueKeysWithValues: fields.map { ($0.parameter, $0) })
        var isValid: Bool {
            colorA.isValid && colorB.isValid && Self.fields.allSatisfy {
                self[keyPath: $0.path].isFinite && $0.range.contains(self[keyPath: $0.path])
            }
        }
        func mixture(atFraction fraction: Double) -> Double {
            let u = min(1, max(0, fraction))
            let t = pattern == .mirrored ? 1 - abs(2 * u - 1) : u
            return pow(t, pow(2, 4 * bias / 100))
        }
        func mixture(at point: CGPoint) -> Double {
            let dx = point.x - x, dy = point.y - y
            let theta = angle * .pi / 180
            let d = shape == .radial ? hypot(dx, dy) : dx * cos(theta) + dy * sin(theta)
            return mixture(atFraction: (d - position) / width + 0.5)
        }
    }
}
