import Foundation
import simd

extension ImageEffects {
    struct RadialRays: Codable, Equatable, Sendable {
        var isEnabled = true
        var x = 960.0
        var y = 540.0
        var length = 1440.0
        var squash = 43.75
        var count = 16.0
        var thickness = 5.0
        var lengthVariation = 35.0
        var variation = 70.0
        var flicker = 65.0
        var intensity = 100.0
        var glow = 18.0
        var coreSize = 120.0
        var coreIntensity = 100.0
        var opacity = 100.0
        var frequency = 15.0
        var color = RGBColor(red: 128.0 / 255, green: 239.0 / 255, blue: 1)
        var seed = UInt32.random(in: .min ... .max)
        var phaseOffset = 0.0

        static let parameters: [ImageParameter] = [.raysX, .raysY, .raysLength, .raysSquash, .raysCount, .raysThickness, .raysLengthVariation, .raysVariation, .raysFlicker, .raysIntensity, .raysGlow, .raysCoreSize, .raysCoreIntensity, .raysOpacity]

        var isValid: Bool {
            let effects = ImageEffects(radialRays: self)
            return Self.parameters.allSatisfy { parameter in
                parameter.effect?.read(effects).map(parameter.accepts) == true
            } && count == count.rounded() && (0...30).contains(frequency) && color.isValid
                && phaseOffset.isFinite && abs(phaseOffset) <= Double.greatestFiniteMagnitude / 1024
        }

        var axisScale: SIMD2<Double> {
            SIMD2(1 - max(0, -squash) / 100, 1 - max(0, squash) / 100)
        }

        var radii: SIMD2<Double> { axisScale * length }

        mutating func fitAspectRatio(width outputWidth: Double, height outputHeight: Double) {
            guard outputWidth.isFinite, outputHeight.isFinite, outputWidth > 0, outputHeight > 0 else { return }
            let value = outputWidth >= outputHeight
                ? (1 - outputHeight / outputWidth) * 100
                : -(1 - outputWidth / outputHeight) * 100
            squash = min(99, max(-99, value))
        }

        struct Instance: Equatable, Sendable {
            // Canvas origin/direction, local rectangle, triangle endpoints, glow/energy/core radii.
            var axis: SIMD4<Float>
            var bounds: SIMD4<Float>
            var triangle: SIMD4<Float>
            var style: SIMD4<Float>
        }

        func instances(at time: Double) -> [Instance] {
            guard isValid, time.isFinite, opacity > 0, intensity > 0 else { return [] }
            let clock = time + phaseOffset
            guard clock.isFinite else { return [] }
            // Reduce the clock before multiplication, including finite times near Double's limit.
            let period = frequency > 0 ? 4_294_967_296 / frequency : 1
            let wrappedClock = frequency > 0 ? clock.truncatingRemainder(dividingBy: period) : 0
            let frameSeed = FocusLineGeometry.frameSeed(seed: seed, time: wrappedClock, frequency: frequency)
            let amount = variation / 100
            let rotation = (ImageEffects.random(seed: frameSeed, index: 0, channel: 10) * 2 - 1) * amount * .pi
            var result: [Instance] = []
            for index in 0..<Int(count) {
                func random(_ channel: UInt32) -> Double { ImageEffects.random(seed: frameSeed, index: index, channel: channel) }
                let fraction = (Double(index) * 0.6180339887498949).truncatingRemainder(dividingBy: 1)
                let angle = fraction * 2 * .pi + rotation + (random(0) * 2 - 1) * amount * 8 * .pi / 180
                let halfAngle = thickness * (1 - 0.75 * amount * random(1)) * .pi / 360
                let reach = 1 - 0.85 * lengthVariation / 100 * random(2)
                let b = SIMD2(cos(angle - halfAngle), sin(angle - halfAngle)) * radii * reach
                let c = SIMD2(cos(angle + halfAngle), sin(angle + halfAngle)) * radii * reach
                let midpoint = (b + c) / 2
                let direction = simd_normalize(midpoint)
                let normal = SIMD2(-direction.y, direction.x)
                let localB = SIMD2(simd_dot(b, direction), simd_dot(b, normal))
                let localC = SIMD2(simd_dot(c, direction), simd_dot(c, normal))
                let padding = glow + 2
                result.append(Instance(axis: SIMD4(Float(x), Float(y), Float(direction.x), Float(direction.y)),
                    bounds: SIMD4(Float(-padding), Float(max(localB.x, localC.x) + padding), Float(min(0, min(localB.y, localC.y)) - padding), Float(max(0, max(localB.y, localC.y)) + padding)),
                    triangle: SIMD4(Float(localB.x), Float(localB.y), Float(localC.x), Float(localC.y)),
                    style: SIMD4(Float(glow), Float(1 - flicker / 100 * random(3)), 0, 0)))
            }
            if coreSize > 0, coreIntensity > 0 {
                let core = SIMD2<Double>(repeating: coreSize / 2)
                let extent = core * 2 + SIMD2(repeating: glow + 2)
                result.append(Instance(axis: SIMD4(Float(x), Float(y), 1, 0),
                    bounds: SIMD4(Float(-extent.x), Float(extent.x), Float(-extent.y), Float(extent.y)), triangle: .zero,
                    style: SIMD4(Float(glow), Float(coreIntensity / 100), Float(core.x), Float(core.y))))
            }
            return result
        }
    }
}
