import Foundation
import simd

enum FocusLineGeometry {
    static func frameSeed(seed: UInt32, time: Double, frequency: Double) -> UInt32 {
        let frame = frequency == 0 ? 0 : floor(time * frequency)
        let bits = UInt32(truncatingIfNeeded: Int64(frame.truncatingRemainder(dividingBy: 4_294_967_296)))
        return seed &+ bits &* 0xD1B54A35
    }

    static func edge(center: SIMD2<Double>, direction: SIMD2<Double>) -> Double {
        var result = Double.infinity
        for (origin, delta, limit) in [(center.x, direction.x, 1920.0), (center.y, direction.y, 1080.0)] {
            if abs(delta) > 1e-12 { result = min(result, ((delta > 0 ? limit : 0) - origin) / delta) }
        }
        return result
    }

    static func inner(direction: SIMD2<Double>, width: Double, height: Double) -> Double {
        let radii = SIMD2(width / 2, height / 2)
        let denominator = (radii.x > 0 ? pow(direction.x / radii.x, 2) : (abs(direction.x) > 1e-12 ? Double.infinity : 0))
            + (radii.y > 0 ? pow(direction.y / radii.y, 2) : (abs(direction.y) > 1e-12 ? Double.infinity : 0))
        return denominator > 0 ? 1 / sqrt(denominator) : 0
    }
}
