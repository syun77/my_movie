import CoreImage
import CoreMedia
import Metal

final class VisualFrame: @unchecked Sendable, Equatable {
    let image: CIImage
    private let identity: AnyObject
    let texture: MTLTexture?
    let referenceBounds: CGRect?
    let pixelBuffer: CVPixelBuffer?
    let presentationTime: CMTime?

    init(_ image: CGImage) {
        referenceBounds = nil; texture = nil
        identity = image; pixelBuffer = nil; presentationTime = nil
        self.image = CIImage(cgImage: image, options: image.colorSpace == nil ? [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!] : [:])
    }

    init(buffer: CVPixelBuffer, transform: CGAffineTransform, presentationTime: CMTime) {
        referenceBounds = nil; texture = nil
        identity = buffer; pixelBuffer = buffer; self.presentationTime = presentationTime
        let oriented = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        image = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
    }

    init(texture: MTLTexture, referenceBounds: CGRect) throws {
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!]) else { throw StudioError.message("Spine画像を作成できません。") }
        self.image = image; self.referenceBounds = referenceBounds
        self.texture = texture
        identity = texture; pixelBuffer = nil; presentationTime = nil
    }

    static func == (lhs: VisualFrame, rhs: VisualFrame) -> Bool { lhs.identity === rhs.identity }
    var width: Int { Int(image.extent.width) }
    var height: Int { Int(image.extent.height) }
}

enum VisualSource: @unchecked Sendable {
    case frame(VisualFrame)
    case spine(SpineDrawPacket)
}

struct VisualRenderLayer: @unchecked Sendable {
    var slot: Int = 1
    let clip: VisualClip
    let source: VisualSource
    var frame: VisualFrame? { if case let .frame(frame) = source { return frame }; return nil }
    init(clip: VisualClip, image: CGImage) { self.clip = clip; source = .frame(VisualFrame(image)) }
    init(clip: VisualClip, frame: VisualFrame) { self.clip = clip; source = .frame(frame) }
    init(clip: VisualClip, spine: SpineDrawPacket) { self.clip = clip; source = .spine(spine) }
}
