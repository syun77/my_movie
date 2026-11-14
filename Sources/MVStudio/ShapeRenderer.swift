import Metal
import Foundation

/// The same geometry uniforms drive colored artwork, masks, and preview guides.
enum ShapeRenderer {
    struct Uniforms {
        var geometry = SIMD4<Float>(960, 540, 400, 400)
        var details = SIMD4<Float>(0, 0, 5, 0.45)
        var color = SIMD4<Float>(1, 1, 1, 1)
        var viewport = SIMD4<Float>(1920, 1080, 0, 1)
        var mask = SIMD4<Float>(0, 0, 0, 0)
    }
    static func uniforms(_ geometry: ShapeGeometry) -> Uniforms {
        var result = Uniforms()
        result.geometry = SIMD4(Float(geometry.x), Float(geometry.y), Float(geometry.width), Float(geometry.height))
        result.details = SIMD4(Float(geometry.rotation * .pi / 180),
                               Float(ShapeGeometry.Kind.allCases.firstIndex(of: geometry.kind) ?? 0),
                               Float(geometry.points), Float(geometry.innerRatio / 100))
        return result
    }
    static func mask(_ value: ImageEffects.Mask?, opacity: Double = 1) -> Uniforms {
        guard let value, value.isEnabled else { return Uniforms() }
        var result = uniforms(value.geometry)
        result.mask = SIMD4(value.inverted ? 1 : 0, Float(value.feather), Float(value.strength / 100 * opacity), 1)
        return result
    }
}
