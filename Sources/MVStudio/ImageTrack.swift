import Foundation

struct ImageAsset: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var reference: AssetReference
    var name: String { URL(fileURLWithPath: reference.path).lastPathComponent }
}

struct ImageClip: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var assetID: UUID
    var start: Double
    var end: Double
    var automaticAnimation = AutomaticAnimation.transient
    var pulseAmount = 0.08
    var fixedValues: [ImageParameter: Double] = [:]
    var curves: [ImageCurve] = []
    var effects: ImageEffects?
}

struct ImageLayer: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var slot: Int
    var clips: [ImageClip] = []
}

struct ImageTrack: Codable, Sendable, Equatable {
    var assets: [ImageAsset] = []
    var layers: [ImageLayer] = (1...3).map { ImageLayer(slot: $0) }
    var clips: [ImageClip] { layers.flatMap(\.clips) }
    func asset(_ id: UUID) -> ImageAsset? { assets.first { $0.id == id } }
    func clip(_ id: UUID?) -> ImageClip? { clips.first { $0.id == id } }
    func slot(of id: UUID) -> Int? { layers.first { $0.clips.contains { $0.id == id } }?.slot }
    func active(at time: Double) -> [ImageClip] {
        layers.sorted { $0.slot < $1.slot }.compactMap { $0.clips.first { $0.start <= time && time < $0.end } }
    }
    func uses(_ id: UUID) -> [ImageClip] { clips.filter { $0.assetID == id } }

    func validate(duration: Double? = nil) throws {
        var ids = Set<UUID>()
        guard layers.count == 3, Set(layers.map(\.slot)) == Set(1...3) else { throw StudioError.message("画像レイヤーは1〜3の3段が必要です。") }
        for asset in assets {
            guard ids.insert(asset.id).inserted, !asset.reference.path.isEmpty else { throw StudioError.message("画像素材の参照が不正です。") }
        }
        let assetIDs = Set(assets.map(\.id))
        for layer in layers {
            guard ids.insert(layer.id).inserted else { throw StudioError.message("画像レイヤーのIDが重複しています。") }
            var previousEnd = 0.0
            for clip in layer.clips {
                guard ids.insert(clip.id).inserted, assetIDs.contains(clip.assetID),
                      clip.start.isFinite, clip.end.isFinite, clip.start >= previousEnd,
                      clip.end - clip.start >= 1.0 / 30 - 1e-9,
                      duration.map({ clip.end <= $0 + 1e-9 }) ?? true else {
                    throw StudioError.message("画像の区間は曲内で、同じレイヤー内では重ならないようにしてください（最小1フレーム）。")
                }
                guard clip.effects?.isValid != false else { throw StudioError.message("画像クリップの追加演出の設定が不正です。") }
                try clip.validateAnimation(ids: &ids)
                previousEnd = clip.end
            }
        }
    }

    mutating func register(url: URL, projectURL: URL) -> UUID {
        let canonical = url.standardizedFileURL
        if let existing = assets.first(where: { $0.reference.resolve(projectURL: projectURL).standardizedFileURL == canonical }) { return existing.id }
        let asset = ImageAsset(reference: AssetReference(url: canonical, projectURL: projectURL))
        assets.append(asset)
        return asset.id
    }

    func replacingAsset(id: UUID, url: URL, projectURL: URL) throws -> ImageTrack {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { throw StudioError.message("画像が見つかりません。") }
        var value = self
        if let existing = assets.first(where: { $0.id != id && $0.reference.resolve(projectURL: projectURL).standardizedFileURL == url.standardizedFileURL }) {
            for layer in value.layers.indices {
                for clip in value.layers[layer].clips.indices where value.layers[layer].clips[clip].assetID == id {
                    value.layers[layer].clips[clip].assetID = existing.id
                }
            }
            value.assets.remove(at: index)
        } else { value.assets[index].reference = AssetReference(url: url.standardizedFileURL, projectURL: projectURL) }
        try value.validate()
        return value
    }

    func removingAsset(id: UUID, includingPlacements: Bool) throws -> ImageTrack {
        guard includingPlacements || uses(id).isEmpty else { throw StudioError.message("使用中の画像です。配置も削除する確認が必要です。") }
        var value = self
        for layer in value.layers.indices { value.layers[layer].clips.removeAll { $0.assetID == id } }
        value.assets.removeAll { $0.id == id }
        try value.validate()
        return value
    }

    func placement(at time: Double, slot: Int, duration: Double, grid: TimelineSnapGrid) throws -> (start: Double, end: Double) {
        guard time.isFinite, time >= 0, time < duration, let layer = layers.first(where: { $0.slot == slot }) else { throw StudioError.message("曲の範囲内の画像行を選んでください。") }
        let start = try grid.snap(time, within: 0...duration)
        guard !layer.clips.contains(where: { $0.start <= start && start < $0.end }) else { throw StudioError.message("配置先が画像と重なっています。空白または別のレイヤーを選んでください。") }
        let limit = min(duration, layer.clips.first(where: { $0.start >= start })?.start ?? duration)
        guard limit - start >= 1.0 / 30 - 1e-9 else { throw StudioError.message("画像を配置する空き時間がありません。") }
        let end = try grid.snap(min(start + 2, limit), within: (start + 1.0 / 30)...limit)
        return (start, end)
    }

    func adding(assetID: UUID, at time: Double, slot: Int, duration: Double, grid: TimelineSnapGrid) throws -> (track: ImageTrack, clip: ImageClip) {
        let range = try placement(at: time, slot: slot, duration: duration, grid: grid)
        let clip = ImageClip(assetID: assetID, start: range.start, end: range.end)
        var value = self
        guard let index = value.layers.firstIndex(where: { $0.slot == slot }) else { throw StudioError.message("画像レイヤーが見つかりません。") }
        value.layers[index].clips.append(clip)
        value.layers[index].clips.sort { $0.start < $1.start }
        try value.validate(duration: duration)
        return (value, clip)
    }

    func updating(_ clip: ImageClip, slot: Int, duration: Double) throws -> ImageTrack {
        var value = removingClip(id: clip.id)
        guard self.clip(clip.id) != nil, let index = value.layers.firstIndex(where: { $0.slot == slot }) else { throw StudioError.message("画像の配置が見つかりません。") }
        value.layers[index].clips.append(clip)
        value.layers[index].clips.sort { $0.start < $1.start }
        try value.validate(duration: duration)
        return value
    }

    func removingClip(id: UUID) -> ImageTrack {
        var value = self
        for layer in value.layers.indices { value.layers[layer].clips.removeAll { $0.id == id } }
        return value
    }

    func dragging(id: UUID, part: TimelineDragPart, delta: Double, duration: Double, grid: TimelineSnapGrid) throws -> ImageTrack {
        try validate(duration: duration)
        guard delta.isFinite, let slot = slot(of: id), let layer = layers.first(where: { $0.slot == slot }), let index = layer.clips.firstIndex(where: { $0.id == id }) else { throw StudioError.message("画像の移動量が不正です。") }
        var clip = layer.clips[index]
        let before = index > 0 ? layer.clips[index - 1].end : 0
        let after = index + 1 < layer.clips.count ? layer.clips[index + 1].start : duration
        switch part {
        case .move:
            let start = try grid.snap(clip.start + delta, within: before...(min(after, duration) - (clip.end - clip.start)))
            clip.end += start - clip.start; clip.start = start
        case .start: clip.trimStart(to: try grid.snap(clip.start + delta, within: before...(clip.end - 1.0 / 30)))
        case .end: clip.end = try grid.snap(clip.end + delta, within: (clip.start + 1.0 / 30)...min(after, duration))
        }
        return try updating(clip, slot: slot, duration: duration)
    }
}
