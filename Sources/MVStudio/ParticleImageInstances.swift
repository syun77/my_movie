import Foundation
import simd

struct ParticleImageInstance: Sendable {
    var geometry: SIMD4<Float>
    var motion: SIMD4<Float>
    var color: SIMD4<Float>
}

extension EffectNode {
    /// Each group preserves emitter order and particle identity independently of the render backend.
    func imageParticleInstances(at localTime: Double, aspect: SIMD2<Float>) -> [[ParticleImageInstance]] {
        guard let appearance = particleAppearance else { return [] }
        let size = SIMD2<Double>(1920, 1080)
        var groups: [([SIMD4<Float>], Double, UInt32)] = []
        var diameter = 1.0
        switch payload {
        case let .particles(v):
            diameter = v.diameter
            groups = v.emitters.map { (v.instances(at: localTime, size: size, emitter: $0), localTime + v.phaseOffset, v.seed &+ $0.phaseSeed) }
        case let .embers(v): diameter = v.diameter; groups = [(v.instances(at: localTime, size: size), localTime + v.phaseOffset, v.seed)]
        case let .snow(v): diameter = v.diameter; groups = [(v.instances(at: localTime, size: size), localTime + v.phaseOffset, v.seed)]
        case let .spiralParticles(v): diameter = v.diameter; groups = [(v.instances(at: localTime), localTime + v.phaseOffset, v.seed)]
        case let .orbs(v): diameter = 60; groups = [(v.instances(at: localTime, size: size), localTime + v.phaseOffset, 0xA3D8E7B1)]
        default: return []
        }
        return groups.map { instances, clock, seed in
            let records = instances.enumerated().map { index, instance -> ParticleImageInstance in
                let angle = appearance.angle + appearance.spin * clock
                    + (ImageEffects.random(seed: seed, index: index, channel: 91) * 2 - 1) * appearance.spread
                let extent = aspect * Float(appearance.size) * instance.z / Float(diameter)
                var tint = SIMD3<Float>(repeating: 1)
                if appearance.colorMode == .effect {
                    switch payload {
                    case let .particles(v):
                        let c = v.color
                        let base = atan2(sqrt(3) * (c.green - c.blue), 2 * c.red - c.green - c.blue + 1e-6) / (2 * .pi)
                        let offset = index == 0 ? 0.5 : (Self.fraction(Double(index) * 0.618034) - 0.5) * 0.25
                        let hue = base + clock / 20 + offset
                        let blend = 0.45 + 0.45 * (max(c.red, max(c.green, c.blue)) - min(c.red, min(c.green, c.blue)))
                        func channel(_ shift: Double) -> Float {
                            let spectrum = min(1, max(0, abs(Self.fraction(hue + shift) * 6 - 3) - 1))
                            return Float(Self.linear(1 + (spectrum - 1) * blend))
                        }
                        tint = SIMD3(channel(0), channel(0.666667), channel(0.333333))
                    case let .spiralParticles(v):
                        tint = SIMD3(Float(Self.linear(v.color.red)), Float(Self.linear(v.color.green)), Float(Self.linear(v.color.blue)))
                    case .embers:
                        tint = SIMD3<Float>(0.95, 0.15, 0.015) + SIMD3<Float>(0.70, 0.49, 0.145) * instance.w
                    case let .orbs(v):
                        let rgb = ImageEffects.Orbs.colors[index]
                        let linear = SIMD3(Float(Self.linear(Double(rgb.x))), Float(Self.linear(Double(rgb.y))), Float(Self.linear(Double(rgb.z))))
                        let luminance = linear.x * 0.2126 + linear.y * 0.7152 + linear.z * 0.0722
                        tint = SIMD3(repeating: luminance) + (linear - SIMD3(repeating: luminance)) * Float(v.saturation / 100)
                    default: break
                    }
                }
                return ParticleImageInstance(geometry: SIMD4(instance.x, instance.y, extent.x, extent.y),
                                     motion: SIMD4(instance.w, Float(angle.truncatingRemainder(dividingBy: 360) * .pi / 180), 0, 0),
                                     color: SIMD4(tint, 1))
            }
            return records
        }
    }
    private static func fraction(_ value: Double) -> Double { value - floor(value) }
    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
