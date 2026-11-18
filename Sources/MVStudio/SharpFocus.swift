import Foundation
import simd

extension ImageEffects {
    struct SharpFocus: Codable, Equatable, Sendable {
        var isEnabled = true
        var x = 960.0
        var y = 540.0
        var width = 480.0
        var height = 270.0
        var count = 120.0
        var thickness = 4.0
        var length = 100.0
        var variation = 75.0
        var opacity = 100.0
        var tipLength = 12.0
        var toneVariation = 65.0
        var frequency = 12.0
        var color = RGBColor.white
        var seed = UInt32.random(in: .min ... .max)
        var phaseOffset = 0.0

        static let parameters: [ImageParameter] = [.sharpX, .sharpY, .sharpWidth, .sharpHeight, .sharpCount,
                                                  .sharpThickness, .sharpLength, .sharpVariation, .sharpOpacity, .sharpTipLength, .sharpToneVariation]

        var isValid: Bool {
            let effects = ImageEffects(sharpFocus: self)
            return Self.parameters.allSatisfy { parameter in
                guard let value = parameter.effect?.read(effects) else { return false }
                return parameter.accepts(value)
            } && count == count.rounded() && (0...30).contains(frequency) && color.isValid
                && phaseOffset.isFinite && abs(phaseOffset) <= Double.greatestFiniteMagnitude / 1024
        }

        struct Line: Equatable, Sendable {
            // Center xy and direction xy; inner distance, outer distance, half-width, tip length.
            var axis: SIMD4<Float>
            var shape: SIMD4<Float>
            var opacityScale: SIMD4<Float>
        }

        func lines(at localTime: Double) -> [Line] {
            guard length > 0, opacity > 0 else { return [] }
            let frameSeed = FocusLineGeometry.frameSeed(seed: seed, time: localTime + phaseOffset, frequency: frequency)
            let amount = variation / 100
            let center = SIMD2(x, y)
            return (0..<Int(count)).compactMap { index in
                func random(_ channel: UInt32) -> Double {
                    ImageEffects.random(seed: frameSeed, index: index, channel: channel)
                }
                let fraction = (Double(index) * 0.6180339887498949).truncatingRemainder(dividingBy: 1)
                let angle = (fraction + amount * (random(0) - 0.5) / 100) * 2 * .pi
                let direction = SIMD2(cos(angle), sin(angle))
                let edge = FocusLineGeometry.edge(center: center, direction: direction)
                guard edge > 0 else { return nil }
                let inner = FocusLineGeometry.inner(direction: direction, width: width, height: height)
                guard inner < edge else { return nil }
                let reach = length / 100
                let scatter = random(1)
                let nearCenter = inner * (0.15 + 0.85 * amount * scatter * scatter)
                let tip = edge * (1 - reach) + nearCenter * reach
                let width = thickness * (1 - amount * random(2) * 0.7)
                let far = edge + 2 * width
                guard far > tip else { return nil }
                let opacityScale = 1 - 0.8 * toneVariation / 100 * random(4)
                return Line(axis: SIMD4(Float(center.x), Float(center.y), Float(direction.x), Float(direction.y)),
                            shape: SIMD4(Float(tip), Float(far), Float(width / 2), Float(min(tipLength, (far - tip) / 2))),
                            opacityScale: SIMD4(Float(opacityScale), 0, 0, 0))
            }
        }
    }
}
