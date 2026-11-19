import CoreImage

/// Thresholds straight sRGB brightness while preserving premultiplied linear RGB and alpha.
enum BinarizationRenderer {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 binarize(__sample image, float threshold, float amount, vec3 darkColor, vec3 lightColor) {
            float carrier = max(image.a, min(1.0, max(image.r, max(image.g, image.b))));
            if (carrier <= 0.0) { return vec4(0.0); }
            vec3 original = image.rgb / carrier;
            vec3 linear = clamp(original, 0.0, 1.0);
            vec3 encoded = mix(12.92 * linear, 1.055 * pow(linear, vec3(1.0 / 2.4)) - 0.055,
                               step(vec3(0.0031308), linear));
            encoded = mix(encoded, vec3(1.0), step(vec3(1.0), linear));
            float brightness = dot(encoded, vec3(0.2126, 0.7152, 0.0722));
            float high = step(threshold, brightness);
            if (threshold <= 0.0) { high = 1.0; }
            if (threshold >= 1.0) { high = 0.0; }
            vec3 color = mix(darkColor, lightColor, high);
            return vec4(mix(original, color, amount) * carrier, image.a);
        }
        """)

    static func apply(_ effect: ImageEffects.Binarization, to image: CIImage) throws -> CIImage {
        guard effect.isActive else { return image }
        func color(_ value: RGBColor) -> CIVector {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return CIVector(x: linear(value.red), y: linear(value.green), z: linear(value.blue))
        }
        guard let result = kernel?.apply(extent: image.extent, arguments: [
            image, effect.threshold / 100, effect.amount / 100, color(effect.darkColor), color(effect.lightColor)
        ]) else { throw MetalSceneRenderer.renderError }
        return result
    }
}
