import CoreImage

/// Elliptical attenuation follows the canvas aspect ratio, preserving linear RGB ratios and alpha.
enum VignetteRenderer {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 opticalVignette(__sample image, vec2 center, vec2 halfSize, float innerRadius, float transitionWidth, float strength) {
            float radius = length((destCoord() - center) / halfSize);
            float t = max(0.0, radius - innerRadius) / transitionWidth;
            float denominator = 1.0 + t * t;
            float transmission = 1.0 / (denominator * denominator);
            float attenuation = mix(1.0, transmission, strength);
            return vec4(image.rgb * attenuation, image.a);
        }
        """)

    static func apply(_ effect: ImageEffects.Vignette, to image: CIImage, canvas: CGRect,
                      padding: Double, scale: Double) throws -> CIImage {
        guard effect.isEnabled, effect.strength > 0 else { return image }
        let radius = sqrt(2.0) * effect.size / 100
        let width = max(scale / min(canvas.width, canvas.height), radius * effect.softness / 100)
        let inner = max(0, radius - width)
        guard let result = kernel?.apply(extent: image.extent, arguments: [
            image, CIVector(x: canvas.midX + padding, y: canvas.midY + padding),
            CIVector(x: canvas.width / 2, y: canvas.height / 2), inner, width, effect.strength / 100
        ]) else { throw MetalSceneRenderer.renderError }
        return result
    }
}
