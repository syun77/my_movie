import AppKit
import SpineBridge

struct SpineBounds: Codable, Sendable, Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 && width <= 16384 && height <= 16384 }
}

struct SpineAnimation: Codable, Sendable, Equatable {
    let name: String
    let duration: Double
}

struct SpineAssetDescriptor: Codable, Sendable, Equatable {
    var atlasReference: AssetReference
    let exportVersion: String
    let referenceBounds: SpineBounds
    let animations: [SpineAnimation]
    var isValid: Bool {
        !atlasReference.path.isEmpty && exportVersion.hasPrefix("4.3.") && referenceBounds.isValid
            && !animations.isEmpty && Set(animations.map(\.name)).count == animations.count
            && animations.allSatisfy { !$0.name.isEmpty && $0.duration.isFinite && $0.duration >= 0 }
    }
}

struct SpinePage: @unchecked Sendable {
    let bytes: Data
    let width: Int
    let height: Int
    let pma: Bool
    let minFilter: Int32
    let magFilter: Int32
    let uWrap: Int32
    let vWrap: Int32
}

final class SpinePages: @unchecked Sendable {
    let revision: String
    let pages: [SpinePage]
    init(revision: String, pages: [SpinePage]) { self.revision = revision; self.pages = pages }
}

struct SpineDrawPacket: @unchecked Sendable {
    let vertices: [MVSpineVertex]
    let indices: [UInt32]
    let commands: [MVSpineCommand]
    let pages: SpinePages
    let referenceBounds: CGRect
    let bounds: CGRect

    init(vertices: [MVSpineVertex], indices: [UInt32], commands: [MVSpineCommand], pages: SpinePages, referenceBounds: CGRect) {
        self.vertices = vertices; self.indices = indices; self.commands = commands
        self.pages = pages; self.referenceBounds = referenceBounds
        var x0 = referenceBounds.minX, x1 = referenceBounds.maxX
        var y0 = referenceBounds.minY, y1 = referenceBounds.maxY
        for v in vertices { x0 = min(x0, Double(v.x)); x1 = max(x1, Double(v.x)); y0 = min(y0, Double(v.y)); y1 = max(y1, Double(v.y)) }
        bounds = CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0).integral
    }
}
