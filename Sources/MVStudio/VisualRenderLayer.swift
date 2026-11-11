import CoreImage
import CoreMedia

final class VisualFrame: @unchecked Sendable, Equatable {
    let image: CIImage
    private let identity: AnyObject
    let pixelBuffer: CVPixelBuffer?
    let presentationTime: CMTime?

    init(_ image: CGImage) {
        identity = image; pixelBuffer = nil; presentationTime = nil
        self.image = CIImage(cgImage: image, options: image.colorSpace == nil ? [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!] : [:])
    }

    init(buffer: CVPixelBuffer, transform: CGAffineTransform, presentationTime: CMTime) {
        identity = buffer; pixelBuffer = buffer; self.presentationTime = presentationTime
        let oriented = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        image = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
    }

    static func == (lhs: VisualFrame, rhs: VisualFrame) -> Bool { lhs.identity === rhs.identity }
    var width: Int { Int(image.extent.width) }
    var height: Int { Int(image.extent.height) }
}

struct VisualRenderLayer: @unchecked Sendable {
    let clip: VisualClip
    let frame: VisualFrame
    init(clip: VisualClip, image: CGImage) { self.clip = clip; frame = VisualFrame(image) }
    init(clip: VisualClip, frame: VisualFrame) { self.clip = clip; self.frame = frame }
}

