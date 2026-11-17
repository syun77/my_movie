import AppKit
import Metal
import XCTest
@testable import MVStudio

final class EffectTestCanvas {
    private(set) var lastEncodeMS = 0.0
    private(set) var lastGPUMS = 0.0
    let renderer: MetalSceneRenderer
    let target: MTLTexture
    let transparent: CGImage
    let clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:])
    init(scale: Double = 1) throws {
        renderer = try MetalSceneRenderer(scale: scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(1920 * scale), height: Int(1080 * scale), mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                            space: MetalSceneRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        transparent = try XCTUnwrap(context.makeImage())
    }
    func draw(_ clips: [(VisualClip, Int)], time: Double = 0.5, guide: UUID? = nil, video: Bool = false) throws {
        let layers = clips.map { clip, slot -> VisualRenderLayer in
            var layer = VisualRenderLayer(clip: clip, image: transparent); layer.slot = slot; return layer
        }
        let begin = ProcessInfo.processInfo.systemUptime
        let commands = try renderer.encode(visuals: layers, features: nil, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), time: time, target: target, video: video, guideClipID: guide)
        lastEncodeMS = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        commands.commit(); commands.waitUntilCompleted()
        lastGPUMS = (commands.gpuEndTime - commands.gpuStartTime) * 1000
        if commands.status != .completed { throw commands.error ?? MetalSceneRenderer.renderError }
    }
    func save(_ path: String) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: target.width, height: target.height, bitsPerComponent: 8, bytesPerRow: target.width * 4,
                                            space: MetalSceneRenderer.sRGB,
                                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        target.getBytes(try XCTUnwrap(context.data), bytesPerRow: context.bytesPerRow,
                        from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4)
        target.getBytes(&result, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return result
    }
}
