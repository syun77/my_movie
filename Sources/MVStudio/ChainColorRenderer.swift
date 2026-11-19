import CoreImage

/// A temporary carrier lets standard color filters process additive radiance without adding coverage.
enum ChainColorRenderer {
    private static let prepare = CIColorKernel(source: """
        kernel vec4 prepareChainColor(__sample image) {
            float carrier = max(image.a, min(1.0, max(image.r, max(image.g, image.b))));
            return vec4(image.rgb, carrier);
        }
        """)
    private static let restore = CIColorKernel(source: """
        kernel vec4 restoreChainColor(__sample corrected, __sample original) {
            return vec4(corrected.rgb, original.a);
        }
        """)
    static func apply(_ value: ImageEffects.ColorCorrection, to image: CIImage) throws -> CIImage {
        guard let input = prepare?.apply(extent: image.extent, arguments: [image]) else { throw MetalSceneRenderer.renderError }
        let filtered = input.applyingFilter("CIHueAdjust", parameters: ["inputAngle": value.hue * .pi / 180])
            .applyingFilter("CIColorControls", parameters: ["inputBrightness": value.brightness / 100, "inputSaturation": value.saturation / 100])
        guard let result = restore?.apply(extent: image.extent, arguments: [filtered, image]) else { throw MetalSceneRenderer.renderError }
        return result
    }
}
