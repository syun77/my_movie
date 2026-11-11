import AppKit
import ImageIO

actor ImageAssetStore {
    private final class Entry: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private let cache = NSCache<NSString, Entry>()
    init() { cache.totalCostLimit = 128 * 1024 * 1024; cache.countLimit = 32 }

    func invalidate() { cache.removeAllObjects() }

    func image(at url: URL, maximumSize: Int = 2400) throws -> CGImage {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.standardizedFileURL.path)|\(modified)|\(attributes[.size] ?? "")|\(maximumSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw StudioError.message("画像を読み込めません: " + url.lastPathComponent) }
        cache.setObject(Entry(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    func layers(track: VisualTrack, projectURL: URL, time: Double, allowMissing: Bool) throws -> [VisualRenderLayer] {
        try track.active(at: time).filter { $0.content == .still }.compactMap { clip in
            guard let asset = track.asset(clip.assetID) else { throw StudioError.message("画像の参照が不正です。") }
            do { return VisualRenderLayer(clip: clip, image: try image(at: asset.reference.resolve(projectURL: projectURL))) }
            catch { if allowMissing { return nil }; throw StudioError.message("画像を確認してください: \(asset.name)（素材管理から置き換え可能）") }
        }
    }

}
