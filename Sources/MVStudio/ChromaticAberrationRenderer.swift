import CoreImage

/// Evaluates the clip clock separately from channel sampling so caching follows the visible pulse.
enum ChromaticAberrationRenderer {
    struct Sample: Equatable {
        let displacement: Double
        let angle: Double
    }
    private static let kernel = CIColorKernel(source: """
        kernel vec4 chromatic(__sample red, __sample green, __sample blue, float gain) {
            return vec4(vec3(red.r, green.g, blue.b) * gain, max(red.a, max(green.a, blue.a)));
        }
        """)

    static func sample(_ effect: ImageEffects.ChromaticAberration, at localTime: Double) -> Sample? {
        let displacement = effect.displacement(at: localTime)
        return displacement > 0 ? Sample(displacement: displacement, angle: effect.angle) : nil
    }

    static func apply(_ sample: Sample, to image: CIImage, bounds: CGRect, scale: Double) throws -> CIImage {
        guard let kernel else { throw MetalSceneRenderer.renderError }
        let radians = sample.angle * .pi / 180
        let dx = cos(radians) * sample.displacement * scale
        let dy = sin(radians) * sample.displacement * scale
        let red = image.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
        let blue = image.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let gain = max(0, 1 - sample.displacement / 1920 * 0.5)
        guard let result = kernel.apply(extent: bounds, arguments: [red, image, blue, gain]) else {
            throw MetalSceneRenderer.renderError
        }
        return result
    }
}
