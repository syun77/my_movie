import Foundation
import CryptoKit
import ImageIO
import SpineBridge

/// Handles and their borrowed arrays stay on SpinePoseProvider's serial executor.
private final class SpineSession {
    let handle: OpaquePointer
    let descriptor: SpineAssetDescriptor
    let pages: SpinePages
    let cost: Int
    deinit { mv_spine_destroy(handle) }

    init(skeletonURL: URL, atlasURL: URL, cancellation: ExportCancellation? = nil) throws {
        let json = try Self.read(skeletonURL, limit: 32 * 1024 * 1024, cancellation: cancellation)
        let atlas = try Self.read(atlasURL, limit: 4 * 1024 * 1024, cancellation: cancellation)
        guard let jsonString = String(data: json, encoding: .utf8), let atlasString = String(data: atlas, encoding: .utf8),
              !jsonString.contains("\0"), !atlasString.contains("\0") else { throw StudioError.message("Spineの文字コードが不正です。") }
        let version = try Self.validateJSON(json)
        var error = [CChar](repeating: 0, count: 1024)
        guard let handle = mv_spine_create(jsonString, atlasString, &error, Int32(error.count)) else { throw StudioError.message(String(cString: error)) }
        self.handle = handle
        do {
            var digest = SHA256(); digest.update(data: json); digest.update(data: atlas)
            var loaded: [SpinePage] = []; var total = json.count + atlas.count
            let folder = atlasURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let count = mv_spine_page_count(handle)
            guard count > 0, count <= 32 else { throw StudioError.message("Spine atlasのページ数が上限を超えています。") }
            for index in 0..<count {
                let name = String(cString: mv_spine_page_name(handle, index))
                let url = folder.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
                guard !name.hasPrefix("/"), !name.contains("://"), url.path.hasPrefix(folder.path + "/"), url.pathExtension.lowercased() == "png" else { throw StudioError.message("atlasのPNGはatlasと同じフォルダ内に置いてください。") }
                let bytes = try Self.read(url, limit: 64 * 1024 * 1024, cancellation: cancellation)
                var info = [Int32](repeating: 0, count: 7); mv_spine_page_info(handle, index, &info)
                let page = try Self.decode(bytes, info: info, cancellation: cancellation)
                total += page.bytes.count
                guard total <= 256 * 1024 * 1024 else { throw StudioError.message("Spine素材は展開後256MiB以内にしてください。") }
                digest.update(data: Data(name.utf8)); digest.update(data: bytes); loaded.append(page)
            }
            let animations = (0..<mv_spine_animation_count(handle)).map {
                SpineAnimation(name: String(cString: mv_spine_animation_name(handle, $0)), duration: mv_spine_animation_duration(handle, $0))
            }
            var b = [Float](repeating: 0, count: 4); mv_spine_bounds(handle, &b)
            descriptor = SpineAssetDescriptor(atlasReference: AssetReference(url: atlasURL, projectURL: URL(fileURLWithPath: "/")), exportVersion: version,
                referenceBounds: SpineBounds(x: Double(b[0]), y: Double(b[1]), width: Double(b[2]), height: Double(b[3])), animations: animations)
            guard descriptor.isValid else { throw StudioError.message("Spineの基準矩形・アニメーションが不正です。") }
            cost = total
            pages = SpinePages(revision: digest.finalize().map { String(format: "%02x", $0) }.joined(), pages: loaded)
        } catch { mv_spine_destroy(handle); throw error }
    }

    func packet(playback: SpinePlayback, time: Double, bounds: CGRect, localTime: Double = 0) throws -> SpineDrawPacket {
        guard playback.isValid, time.isFinite, time >= 0 else { throw StudioError.message("Spineの再生時刻が不正です。") }
        var error = [CChar](repeating: 0, count: 1024)
        guard playback.names.isSubset(of: Set(descriptor.animations.map(\.name))) else { throw StudioError.message("Spineのアニメーション名を確認してください。") }
        let request = playback.resolved(at: localTime)
        guard mv_spine_evaluate(handle, request.animation, request.secondAnimation ?? "", request.weight, time, playback.loop ? 1 : 0, &error, Int32(error.count)) == 1 else { throw StudioError.message(String(cString: error)) }
        var n: Int32 = 0
        let vp = mv_spine_vertices(handle, &n); let vertices = Array(UnsafeBufferPointer(start: vp, count: Int(n)))
        let ip = mv_spine_indices(handle, &n); let indices = Array(UnsafeBufferPointer(start: ip, count: Int(n)))
        let cp = mv_spine_commands(handle, &n); let commands = Array(UnsafeBufferPointer(start: cp, count: Int(n)))
        let packet = SpineDrawPacket(vertices: vertices, indices: indices, commands: commands, pages: pages, referenceBounds: bounds)
        guard packet.bounds.width <= 16384, packet.bounds.height <= 16384,
              packet.bounds.width * packet.bounds.height * 8 <= 256 * 1024 * 1024 else { throw StudioError.message("Spineの描画領域が上限を超えています。") }
        return packet
    }

    private static func read(_ url: URL, limit: Int, cancellation: ExportCancellation?) throws -> Data {
        try Task.checkCancellation(); try cancellation?.check()
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size > 0, size <= limit else { throw StudioError.message("Spineファイルのサイズが不正です: " + url.lastPathComponent) }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw StudioError.message("Spineファイルが大きすぎます。") }
        try Task.checkCancellation(); try cancellation?.check()
        return data
    }

    private static func decode(_ data: Data, info: [Int32], cancellation: ExportCancellation?) throws -> SpinePage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 32 * 1024 * 1024,
              width == Int(info[0]), height == Int(info[1]),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.bitsPerComponent == 8, [24, 32].contains(image.bitsPerPixel),
              let raw = image.dataProvider?.data, let pointer = CFDataGetBytePtr(raw) else { throw StudioError.message("atlasのPNG形式・寸法が不正です（8bit RGB/RGBA）。") }
        let alpha = image.alphaInfo
        let first = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha)
        let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast
        let little = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        let stride = image.bitsPerPixel / 8
        var rgba = Data(count: width * height * 4)
        try rgba.withUnsafeMutableBytes { out in
            let dst = out.bindMemory(to: UInt8.self)
            for y in 0..<height {
                if y % 64 == 0 { try Task.checkCancellation(); try cancellation?.check() }
                for x in 0..<width {
                let p = pointer + y * image.bytesPerRow + x * stride
                var c = (0..<stride).map { p[$0] }
                if little && stride == 4 { c.reverse() }
                let a: UInt8 = hasAlpha ? c[first ? 0 : 3] : 255
                let offset = first ? 1 : 0, i = (y * width + x) * 4
                for channel in 0..<3 {
                    let value = c[offset + channel]
                    dst[i + channel] = premultiplied && a > 0 ? UInt8(min(255, Int(value) * 255 / Int(a))) : value
                }
                dst[i + 3] = a
            } }
        }
        return SpinePage(bytes: rgba, width: width, height: height, pma: info[2] != 0, minFilter: info[3], magFilter: info[4], uWrap: info[5], vWrap: info[6])
    }

    private static func validateJSON(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["skeleton"] as? [String: Any], let version = header["spine"] as? String, version.hasPrefix("4.3."),
              let bones = root["bones"] as? [[String: Any]], !bones.isEmpty, bones.count <= 4096,
              let slots = root["slots"] as? [[String: Any]], slots.count <= 4096,
              let skins = root["skins"] as? [[String: Any]], skins.count == 1, skins[0]["name"] as? String == "default",
              let animations = root["animations"] as? [String: Any], !animations.isEmpty else { throw StudioError.message("初期Spine対応は4.3 JSON・default skinのみです。") }
        for key in ["ik", "transform", "path", "physics", "sliders", "constraints"] where root[key] != nil { throw StudioError.message("Spineの制約は初期対応の対象外です: " + key) }
        for slot in slots where (slot["blend"] as? String ?? "normal") != "normal" || slot["dark"] != nil { throw StudioError.message("Spineの特殊ブレンド・tint blackは初期対応の対象外です。") }
        for (_, raw) in animations {
            guard let animation = raw as? [String: Any], Set(animation.keys).isSubset(of: ["bones"]) else { throw StudioError.message("Spineはボーンの移動・回転アニメーションに対応しています。") }
            for (_, rawBone) in animation["bones"] as? [String: Any] ?? [:] {
                guard let timelines = rawBone as? [String: Any], Set(timelines.keys).isSubset(of: ["rotate", "translate", "translatex", "translatey"]) else { throw StudioError.message("Spineの移動・回転以外のキーは初期対応の対象外です。") }
            }
        }
        try validateGeometry(bones: bones, slots: slots, skins: skins, animations: animations)
        return version
    }
    private static func validateGeometry(bones: [[String: Any]], slots: [[String: Any]], skins: [[String: Any]], animations: [String: Any]) throws {
        func reject() throws -> Never { throw StudioError.message("Spineのボーン・頂点・参照・キーが不正です。") }
        var boneNames = Set<String>()
        for bone in bones {
            guard let name = bone["name"] as? String, !name.isEmpty, boneNames.insert(name).inserted else { try reject() }
            if let parent = bone["parent"] as? String, parent == name || !boneNames.contains(parent) { try reject() }
        }
        var slotNames = Set<String>()
        for slot in slots {
            guard let name = slot["name"] as? String, slotNames.insert(name).inserted,
                  let bone = slot["bone"] as? String, boneNames.contains(bone) else { try reject() }
        }
        guard let attachments = skins[0]["attachments"] as? [String: [String: [String: Any]]] else { try reject() }
        var total = 0
        for (slot, values) in attachments {
            guard slotNames.contains(slot) else { try reject() }
            for (_, value) in values {
                let type = value["type"] as? String ?? "region"
                guard ["region", "mesh", "clipping"].contains(type), value["sequence"] == nil else { throw StudioError.message("Spine attachmentの形式は初期対応の対象外です。") }
                if type == "region" {
                    guard let w = value["width"] as? Double, let h = value["height"] as? Double, w > 0, h > 0 else { try reject() }
                    continue
                }
                guard let vertices = value["vertices"] as? [Double], vertices.allSatisfy(\.isFinite) else { try reject() }
                let count: Int
                if type == "mesh" {
                    guard let uvs = value["uvs"] as? [Double], uvs.count % 2 == 0, uvs.allSatisfy(\.isFinite),
                          let triangles = value["triangles"] as? [Int], triangles.count % 3 == 0,
                          triangles.allSatisfy({ $0 >= 0 && $0 < uvs.count / 2 }) else { try reject() }
                    count = uvs.count / 2
                } else {
                    guard let n = value["vertexCount"] as? Int, n >= 3 else { try reject() }; count = n
                    if let end = value["end"] as? String, !slotNames.contains(end) { try reject() }
                }
                total += count
                guard count > 0, count <= 65535, total <= 1000000 else { try reject() }
                if vertices.count != count * 2 {
                    var i = 0
                    for _ in 0..<count {
                        guard i < vertices.count, vertices[i] >= 1, vertices[i] <= Double(bones.count), vertices[i].rounded() == vertices[i] else { try reject() }
                        let influences = Int(vertices[i]); i += 1; var weight = 0.0
                        for _ in 0..<influences {
                            guard i + 4 <= vertices.count, vertices[i] >= 0, vertices[i] < Double(bones.count), vertices[i].rounded() == vertices[i], vertices[i+3] >= 0 else { try reject() }
                            weight += vertices[i+3]; i += 4
                        }
                        guard abs(weight-1) < 0.001 else { try reject() }
                    }
                    guard i == vertices.count else { try reject() }
                }
            }
        }
        var keyCount = 0
        for (_, value) in animations {
            let timelines = (value as? [String: Any])?["bones"] as? [String: [String: Any]] ?? [:]
            for (bone, channels) in timelines {
                guard boneNames.contains(bone) else { try reject() }
                for (_, channel) in channels {
                    guard let keys = channel as? [[String: Any]], !keys.isEmpty else { try reject() }
                    var previous = -1.0
                    for key in keys {
                        let time = key["time"] as? Double ?? 0
                        guard time.isFinite, time >= 0, time > previous else { try reject() }
                        previous = time
                    }
                    keyCount += keys.count
                    guard keyCount <= 1000000 else { try reject() }
                }
            }
        }
    }

}

actor SpinePoseProvider {
    private var sessions: [String: SpineSession] = [:]
    private var order: [String] = []
    private var pinned = false
    func invalidate() { sessions.removeAll(); order.removeAll(); pinned = false }

    private func session(skeleton: URL, atlas: URL, cancellation: ExportCancellation? = nil) throws -> SpineSession {
        let key = skeleton.standardizedFileURL.path + "\n" + atlas.standardizedFileURL.path
        if let value = sessions[key] { order.removeAll { $0 == key }; order.append(key); return value }
        let value = try SpineSession(skeletonURL: skeleton, atlasURL: atlas, cancellation: cancellation)
        while sessions.values.reduce(value.cost, { $0 + $1.cost }) > 256 * 1024 * 1024 || sessions.count >= 16 {
            guard !pinned, let old = order.first else { throw StudioError.message("Spine素材キャッシュの上限を超えています。") }
            order.removeFirst(); sessions[old] = nil
        }
        sessions[key] = value; order.append(key); return value
    }

    func inspect(skeleton: URL, atlas: URL) throws -> (SpineAssetDescriptor, SpineDrawPacket) {
        let value = try session(skeleton: skeleton, atlas: atlas)
        let playback = SpinePlayback(animationName: value.descriptor.animations[0].name)
        return (value.descriptor, try value.packet(playback: playback, time: 0, bounds: value.descriptor.referenceBounds.rect))
    }

    func prepare(track: VisualTrack, projectURL: URL, cancellation: ExportCancellation?) throws {
        invalidate(); pinned = true
        for id in Set(track.clips.compactMap(\.assetID)) {
            try cancellation?.check(); try Task.checkCancellation()
            guard let asset = track.asset(id), case let .spine(descriptor) = asset.kind else { continue }
            let value = try session(skeleton: asset.reference.resolve(projectURL: projectURL), atlas: descriptor.atlasReference.resolve(projectURL: projectURL), cancellation: cancellation)
            for clip in track.uses(id) {
                guard case let .spine(playback) = clip.content else { throw StudioError.message("Spineの配置が不正です。") }
                _ = try value.packet(playback: playback, time: playback.sourceIn, bounds: descriptor.referenceBounds.rect)
            }
        }
    }

    func layers(track: VisualTrack, projectURL: URL, time: Double, cancellation: ExportCancellation?) throws -> [VisualRenderLayer] {
        try track.active(at: time).compactMap { clip in
            try Task.checkCancellation(); try cancellation?.check()
            guard case let .spine(playback) = clip.content, let asset = track.asset(clip.assetID), case let .spine(descriptor) = asset.kind else { return nil }
            let value = try session(skeleton: asset.reference.resolve(projectURL: projectURL), atlas: descriptor.atlasReference.resolve(projectURL: projectURL), cancellation: cancellation)
            let packet = try value.packet(playback: playback, time: clip.sourceTime(at: time), bounds: descriptor.referenceBounds.rect, localTime: time - clip.start)
            return VisualRenderLayer(clip: clip, spine: packet)
        }
    }
}
