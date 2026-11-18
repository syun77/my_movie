import Foundation
import simd

extension ImageEffects {
    struct StraightLines: Codable, Equatable, Sendable {
        var isEnabled = true
        var angle = 0.0
        var count = 40.0
        var length = 800.0
        var thickness = 2.0
        var speed = 1600.0
        var lengthVariation = 65.0
        var thicknessVariation = 50.0
        var toneVariation = 60.0
        var fade = 15.0
        var glow = 25.0
        var opacity = 80.0
        var color = RGBColor(red: 221.0 / 255, green: 238.0 / 255, blue: 1)
        var seed = UInt32.random(in: .min ... .max)
        var phaseOffset = 0.0

        static let parameters: [ImageParameter] = [.straightAngle, .straightCount, .straightLength, .straightThickness, .straightSpeed, .straightLengthVariation, .straightThicknessVariation, .straightToneVariation, .straightFade, .straightGlow, .straightOpacity]
        var isValid: Bool {
            let effects = ImageEffects(straightLines: self)
            return Self.parameters.allSatisfy { parameter in
                parameter.effect?.read(effects).map(parameter.accepts) == true
            } && count == count.rounded() && color.isValid && phaseOffset.isFinite
                && abs(phaseOffset) <= Double.greatestFiniteMagnitude / 16384
        }

        struct Line: Equatable, Sendable {
            var axis: SIMD4<Float>
            // Half-length, half-width, end fade length, glow radius in canvas pixels.
            var shape: SIMD4<Float>
            var opacityScale: SIMD4<Float>
        }

        func lines(at time: Double) -> [Line] {
            guard isValid, count > 0, opacity > 0, time.isFinite else { return [] }
            let radians = angle * .pi / 180
            let direction = SIMD2(cos(radians), sin(radians))
            let normal = SIMD2(-direction.y, direction.x)
            let extent = abs(direction.x) * 1920 + abs(direction.y) * 1080
            let crossExtent = abs(normal.x) * 1920 + abs(normal.y) * 1080
            let radius = max(2, thickness * 3)
            let period = extent + length + radius * 2 + 4
            let clock = time + phaseOffset
            // Reduce before multiplying to keep long seeks finite.
            let travel = speed == 0 ? 0 : clock.truncatingRemainder(dividingBy: period / speed) * speed
            var result: [Line] = []
            for index in 0..<Int(count) {
                func random(_ channel: UInt32) -> Double { ImageEffects.random(seed: seed, index: index, channel: channel) }
                let size = length * (1 - lengthVariation / 100 * random(2))
                let width = max(0.5, thickness * (1 - thicknessVariation / 100 * random(3)))
                let longitudinal = random(0) * period + travel
                let position = longitudinal - floor(longitudinal / period) * period - period / 2
                let transverse = (random(1) - 0.5) * crossExtent
                for copy in -1...1 {
                    let along = position + Double(copy) * period
                    guard abs(along) <= extent / 2 + size / 2 + radius + 2 else { continue }
                    let center = SIMD2(960.0, 540.0) + direction * along + normal * transverse
                    result.append(Line(axis: SIMD4(Float(center.x), Float(center.y), Float(direction.x), Float(direction.y)),
                                       shape: SIMD4(Float(size / 2), Float(width / 2), Float(size * fade / 100), Float(max(2, width * 3))),
                                       opacityScale: SIMD4(Float(1 - toneVariation / 100 * random(4)), 0, 0, 0)))
                }
            }
            return result
        }
    }
}
