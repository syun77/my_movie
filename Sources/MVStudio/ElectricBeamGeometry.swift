import Foundation
import simd

/// Screen-space segments use a deterministic, quantized clock independent of render order.
enum ElectricBeamGeometry {
    struct Segment: Equatable {
        var endpoints: SIMD4<Float>
        var widths: SIMD4<Float>
    }
    struct Key: Equatable {
        let x, y, angle, length, spread, count, width, bend: Double
        let seed: UInt32
        let frame: Int64
        init(_ beam: ImageEffects.ElectricBeam, at time: Double) {
            x = beam.x; y = beam.y; angle = beam.angle; length = beam.length
            spread = beam.spread; count = beam.count.rounded(); width = beam.width; bend = beam.bend
            seed = beam.seed; frame = beam.frame(at: time)
        }
    }

    static func paths(_ key: Key) -> [[Segment]] {
        let direction = SIMD2(cos(key.angle * .pi / 180), sin(key.angle * .pi / 180))
        let normal = SIMD2(-direction.y, direction.x)
        let center = SIMD2(key.x, key.y)
        let segments = min(64, max(8, Int(ceil(key.length / 120))))
        // A bounded phase avoids loss of precision after long playback and supports negative time.
        let phase = Double((key.frame % 24576 + 24576) % 24576) / 24 * 5
        return (0..<Int(key.count)).map { ray in
            let seed = key.seed &+ UInt32(ray) &* 0x9e3779b9
            let offset = (random(seed, 0) - 0.5) * key.spread
            let points = (0...segments).map { index -> SIMD2<Double> in
                let u = Double(index) / Double(segments)
                let position = Double(index) + phase
                let cell = Int(floor(position))
                let f = position - floor(position)
                let smooth = f * f * (3 - 2 * f)
                let noise = random(seed, cell + 1) * (1 - smooth) + random(seed, cell + 2) * smooth
                let jagged = random(seed ^ UInt32(truncatingIfNeeded: key.frame), index + 901)
                let shift = ((noise * 0.65 + jagged * 0.35) * 2 - 1) * key.bend * sin(u * .pi)
                return center + direction * ((u - 0.5) * key.length) + normal * (offset + shift)
            }
            let thickness = Float(key.width * (0.65 + random(seed, 803) * 0.35) / 2)
            return (0..<segments).compactMap { i in
                let a = points[i], b = points[i + 1]
                guard simd_length_squared(b - a) > 1e-12 else { return nil }
                return Segment(endpoints: SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y)),
                               widths: SIMD4(thickness, 0, 0, 0))
            }
        }
    }

    private static func random(_ seed: UInt32, _ index: Int) -> Double {
        var n = seed &+ UInt32(truncatingIfNeeded: index) &* 0x85ebca6b
        n = (n ^ (n >> 16)) &* 0x7feb352d
        n = (n ^ (n >> 15)) &* 0x846ca68b
        return Double(n ^ (n >> 16)) / Double(UInt32.max)
    }
}
