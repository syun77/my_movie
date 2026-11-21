import Foundation
import simd

extension ImageEffects {
    struct SpiralParticles: Codable, Equatable, Sendable {
        enum Direction: String, Codable, CaseIterable, Sendable {
            case clockwise, counterclockwise
            var title: String { self == .clockwise ? "時計回り" : "反時計回り" }
        }
        var isEnabled = true
        var x = 960.0
        var y = 540.0
        var radius = 1200.0
        var count = 200.0
        var convergenceTime = 3.0
        var turns = 1.5
        var speed = 100.0
        var diameter = 8.0
        var opacity = 100.0
        var glowWidth = 8.0
        var glowStrength = 100.0
        var direction = Direction.clockwise
        var color = RGBColor(red: 0.65, green: 0.9, blue: 1)
        var seed = UInt32.random(in: .min ... .max)
        var phaseOffset = 0.0

        struct Field {
            let parameter: ImageParameter
            let title: String
            let unit: String
            let path: WritableKeyPath<SpiralParticles, Double>
            let range: ClosedRange<Double>
        }
        static let fields: [Field] = [
            Field(parameter: .spiralX, title: "中心X", unit: "px", path: \.x, range: -1920...3840),
            Field(parameter: .spiralY, title: "中心Y", unit: "px", path: \.y, range: -1080...2160),
            Field(parameter: .spiralRadius, title: "発生半径", unit: "px", path: \.radius, range: 0...3000),
            Field(parameter: .spiralCount, title: "粒子数", unit: "", path: \.count, range: 1...1000),
            Field(parameter: .spiralConvergenceTime, title: "収束時間", unit: "秒", path: \.convergenceTime, range: 0.25...20),
            Field(parameter: .spiralTurns, title: "回転数", unit: "周", path: \.turns, range: 0...8),
            Field(parameter: .spiralSpeed, title: "速度", unit: "%", path: \.speed, range: 0...400),
            Field(parameter: .spiralDiameter, title: "粒の大きさ", unit: "px", path: \.diameter, range: 1...200),
            Field(parameter: .spiralGlowWidth, title: "ぼかしの幅", unit: "px", path: \.glowWidth, range: 0...200),
            Field(parameter: .spiralGlowStrength, title: "ぼかしの強さ", unit: "%", path: \.glowStrength, range: 0...200),
            Field(parameter: .spiralOpacity, title: "不透明度", unit: "%", path: \.opacity, range: 0...100)
        ]
        static let fieldsByParameter = Dictionary(uniqueKeysWithValues: fields.map { ($0.parameter, $0) })
        var isValid: Bool {
            color.isValid && phaseOffset.isFinite && abs(phaseOffset) < 1e12 && Self.fields.allSatisfy {
                self[keyPath: $0.path].isFinite && $0.range.contains(self[keyPath: $0.path])
            }
        }
        func lifetime(index: Int) -> Double {
            convergenceTime * (0.85 + 0.3 * ImageEffects.random(seed: seed, index: index, channel: 0))
        }
        func phase(index: Int) -> Double {
            Self.fraction(Double(index) * 0.6180339887498949 + 0.08 * ImageEffects.random(seed: seed, index: index, channel: 1))
        }
        func instance(index: Int, progress u: Double) -> SIMD4<Float> {
            let r = radius * (0.8 + 0.2 * ImageEffects.random(seed: seed, index: index, channel: 2)) * pow(1 - u, 1.5)
            let angle = 2 * Double.pi * (ImageEffects.random(seed: seed, index: index, channel: 3)
                + (direction == .clockwise ? 1 : -1) * turns * u)
            let fade = Self.smooth(u / 0.08) * (1 - Self.smooth((u - 0.85) / 0.15))
            let shrink = 1 - Self.smooth((u - 0.85) / 0.15)
            let size = diameter * (0.65 + 0.7 * ImageEffects.random(seed: seed, index: index, channel: 4)) * shrink
            return SIMD4(Float(x + r * cos(angle)), Float(y + r * sin(angle)), Float(size), Float(fade * opacity / 100))
        }
        func instances(at localTime: Double) -> [SIMD4<Float>] {
            let clock = (localTime + phaseOffset) * speed / 100
            return (0..<Int(count.rounded())).map { i in
                instance(index: i, progress: Self.fraction(clock / lifetime(index: i) + phase(index: i)))
            }
        }
        private static func fraction(_ value: Double) -> Double { value - floor(value) }
        private static func smooth(_ value: Double) -> Double {
            let t = min(1, max(0, value)); return t * t * (3 - 2 * t)
        }
    }
}
