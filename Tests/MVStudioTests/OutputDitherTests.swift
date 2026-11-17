import Metal
import XCTest
@testable import MVStudio

final class OutputDitherTests: XCTestCase {
    func testOutputQuantizationMeanNeutralityEndpointsAndRepeatability() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try SceneShaders.library(device: device)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name: "outputColor")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        sourceDescriptor.storageMode = .shared; sourceDescriptor.usage = [.shaderRead]
        let source = try XCTUnwrap(device.makeTexture(descriptor: sourceDescriptor))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 256, mipmapped: false)
        targetDescriptor.storageMode = .shared; targetDescriptor.usage = [.renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        func draw(code: Double, video: Bool) throws -> [UInt8] {
            let encoded = code / 255
            let linear: Double
            if video {
                linear = encoded < 0.081 ? encoded / 4.5 : pow((encoded + 0.099) / 1.099, 1 / 0.45)
            } else {
                linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            }
            var color = SIMD4<Float>(Float(linear), Float(linear), Float(linear), 1)
            source.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &color, bytesPerRow: 16)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            var transfer: UInt32 = video ? 1 : 0
            encoder.setFragmentBytes(&transfer, length: 4, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
            target.getBytes(&bytes, bytesPerRow: 256 * 4, from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
            return bytes
        }
        for video in [false, true] {
            for code in [0.0, 255, 5.25, 51.25, 127.25, 240.25] {
                let first = try draw(code: code, video: video)
                XCTAssertEqual(first, try draw(code: code, video: video))
                let values = stride(from: 0, to: first.count, by: 4).map { index -> UInt8 in
                    XCTAssertEqual(first[index], first[index + 1])
                    XCTAssertEqual(first[index], first[index + 2])
                    XCTAssertEqual(first[index + 3], 255)
                    return first[index]
                }
                let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
                XCTAssertEqual(mean, code, accuracy: 0.03, "量子化の平均値を保つ")
                XCTAssertLessThanOrEqual(Double(try XCTUnwrap(values.max())) - code, 1)
                XCTAssertLessThanOrEqual(code - Double(try XCTUnwrap(values.min())), 1)
                XCTAssertEqual(Set(values).count, code == 0 || code == 255 ? 1 : 2)
            }
        }
    }
}
