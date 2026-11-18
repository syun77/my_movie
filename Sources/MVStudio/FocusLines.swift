import Foundation
import simd

extension ImageEffects {
    struct FocusLines: Codable, Equatable, Sendable {
        var isEnabled = true
        var x = 960.0
        var y = 540.0
        var width = 640.0
        var height = 360.0
        var count = 100.0
        var thickness = 8.0
        var length = 100.0
        var variation = 60.0
        var opacity = 100.0
        var frequency = 12.0
        var color = RGBColor.black
        var seed = UInt32.random(in: .min ... .max)
        var phaseOffset = 0.0

        static let parameters: [ImageParameter] = [.focusX, .focusY, .focusWidth, .focusHeight, .focusCount,
                                                  .focusThickness, .focusLength, .focusVariation, .focusOpacity]

        var isValid: Bool {
            let effects = ImageEffects(focusLines: self)
            return Self.parameters.allSatisfy { parameter in
                guard let value = parameter.effect?.read(effects) else { return false }
                return parameter.accepts(value)
            } && count == count.rounded() && (0...30).contains(frequency) && color.isValid
                && phaseOffset.isFinite && abs(phaseOffset) <= Double.greatestFiniteMagnitude / 1024
        }

        struct Line: Equatable, Sendable {
            // Center xy, direction xy; tip distance, far distance, far half-width, unused.
            var axis: SIMD4<Float>
            var shape: SIMD4<Float>
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
                let reach = length / 100 * (1 - amount * random(1) * 0.45)
                let tip = edge - (edge - inner) * reach
                // Beyond every canvas corner, including the width of the triangle.
                let far = 5000.0
                let halfWidth = thickness * far / 2000 * (1 - amount * random(2) * 0.7)
                return Line(axis: SIMD4(Float(center.x), Float(center.y), Float(direction.x), Float(direction.y)),
                            shape: SIMD4(Float(tip), Float(far), Float(halfWidth), 0))
            }
        }
    }
}
