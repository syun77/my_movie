import Foundation

enum VisualAssetKind: Codable, Sendable, Equatable {
    case still
    case video(duration: Double)

    var videoDuration: Double? { if case let .video(duration) = self { return duration }; return nil }
}

enum VisualContent: Codable, Sendable, Equatable {
    case still
    case video(sourceIn: Double)

    var sourceIn: Double? { if case let .video(value) = self { return value }; return nil }
}

struct VisualAsset: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var reference: AssetReference
    var kind: VisualAssetKind = .still
    var name: String { URL(fileURLWithPath: reference.path).lastPathComponent }
}

struct VisualClip: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var assetID: UUID
    var start: Double
    var end: Double
    var content: VisualContent = .still
    var audioModulations: [ImageParameter: AudioModulation] = [.scale: .initial(for: .scale)]
    var automationRanges: [ImageParameter: DisplayRange] = [:]
    var fixedValues: [ImageParameter: Double] = [:]
    var curves: [ImageCurve] = []
    var effects: ImageEffects?
}

struct VisualLayer: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var slot: Int
    var clips: [VisualClip] = []
}

struct VisualTrack: Codable, Sendable, Equatable {
    var assets: [VisualAsset] = []
    var layers: [VisualLayer] = (1...3).map { VisualLayer(slot: $0) }
    var clips: [VisualClip] { layers.flatMap(\.clips) }
    func asset(_ id: UUID) -> VisualAsset? { assets.first { $0.id == id } }
    func clip(_ id: UUID?) -> VisualClip? { clips.first { $0.id == id } }
    func slot(of id: UUID) -> Int? { layers.first { $0.clips.contains { $0.id == id } }?.slot }
    func active(at time: Double) -> [VisualClip] {
        layers.sorted { $0.slot < $1.slot }.compactMap { $0.clips.first { $0.start <= time && time < $0.end } }
    }
    func uses(_ id: UUID) -> [VisualClip] { clips.filter { $0.assetID == id } }

    func validate(duration: Double? = nil) throws {
        var ids = Set<UUID>()
        guard layers.count == 3, Set(layers.map(\.slot)) == Set(1...3) else { throw StudioError.message("素材レイヤーは1〜3の3段が必要です。") }
        for asset in assets {
            guard ids.insert(asset.id).inserted, !asset.reference.path.isEmpty, asset.kind.videoDuration.map({ $0.isFinite && $0 > 0 }) ?? true else { throw StudioError.message("素材素材の参照が不正です。") }
        }
        let assetIDs = Set(assets.map(\.id))
        for layer in layers {
            guard ids.insert(layer.id).inserted else { throw StudioError.message("素材レイヤーのIDが重複しています。") }
            var previousEnd = 0.0
            for clip in layer.clips {
                guard ids.insert(clip.id).inserted, assetIDs.contains(clip.assetID),
                      clip.start.isFinite, clip.end.isFinite, clip.start >= previousEnd,
                      clip.end - clip.start >= 1.0 / 30 - 1e-9,
                      duration.map({ clip.end <= $0 + 1e-9 }) ?? true else {
                    throw StudioError.message("素材の区間は曲内で、同じレイヤー内では重ならないようにしてください（最小1フレーム）。")
                }
                guard let asset = asset(clip.assetID) else { throw StudioError.message("素材が見つかりません。") }
                switch (asset.kind, clip.content) {
                case (.still, .still): break
                case let (.video(length), .video(sourceIn)):
                    guard sourceIn.isFinite, sourceIn >= 0, sourceIn + clip.end - clip.start <= length + 1e-9 else {
                        throw StudioError.message("動画の参照区間が素材の長さを超えています。")
                    }
                default: throw StudioError.message("素材とクリップの種類が一致しません。")
                }
                guard clip.effects?.isValid != false else { throw StudioError.message("素材クリップの追加演出の設定が不正です。") }
                try clip.validateAnimation(ids: &ids)
                previousEnd = clip.end
            }
        }
    }

    mutating func register(url: URL, projectURL: URL, kind: VisualAssetKind = .still) -> UUID {
        let canonical = url.standardizedFileURL
        if let index = assets.firstIndex(where: { $0.reference.resolve(projectURL: projectURL).standardizedFileURL == canonical }) {
            assets[index].kind = kind
            return assets[index].id
        }
        let asset = VisualAsset(reference: AssetReference(url: canonical, projectURL: projectURL), kind: kind)
        assets.append(asset)
        return asset.id
    }

    func replacingAsset(id: UUID, url: URL, projectURL: URL, kind: VisualAssetKind = .still) throws -> VisualTrack {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { throw StudioError.message("素材が見つかりません。") }
        guard (assets[index].kind.videoDuration != nil) == (kind.videoDuration != nil) else { throw StudioError.message("同じ種類の素材で置き換えてください。") }
        var value = self
        value.assets[index].kind = kind
        if let existing = assets.first(where: { $0.id != id && $0.reference.resolve(projectURL: projectURL).standardizedFileURL == url.standardizedFileURL }) {
            if let existingIndex = value.assets.firstIndex(where: { $0.id == existing.id }) { value.assets[existingIndex].kind = kind }
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

    func removingAsset(id: UUID, includingPlacements: Bool) throws -> VisualTrack {
        guard includingPlacements || uses(id).isEmpty else { throw StudioError.message("使用中の素材です。配置も削除する確認が必要です。") }
        var value = self
        for layer in value.layers.indices { value.layers[layer].clips.removeAll { $0.assetID == id } }
        value.assets.removeAll { $0.id == id }
        try value.validate()
        return value
    }

    func placement(at time: Double, slot: Int, duration: Double, grid: TimelineSnapGrid) throws -> (start: Double, end: Double) {
        guard time.isFinite, time >= 0, time < duration, let layer = layers.first(where: { $0.slot == slot }) else { throw StudioError.message("曲の範囲内の素材行を選んでください。") }
        let start = try grid.snap(time, within: 0...duration)
        guard !layer.clips.contains(where: { $0.start <= start && start < $0.end }) else { throw StudioError.message("配置先が素材と重なっています。空白または別のレイヤーを選んでください。") }
        let limit = min(duration, layer.clips.first(where: { $0.start >= start })?.start ?? duration)
        guard limit - start >= 1.0 / 30 - 1e-9 else { throw StudioError.message("素材を配置する空き時間がありません。") }
        let end = try grid.snap(min(start + 2, limit), within: (start + 1.0 / 30)...limit)
        return (start, end)
    }

    func adding(assetID: UUID, at time: Double, slot: Int, duration: Double, grid: TimelineSnapGrid) throws -> (track: VisualTrack, clip: VisualClip) {
        var range = try placement(at: time, slot: slot, duration: duration, grid: grid)
        guard let asset = asset(assetID) else { throw StudioError.message("素材が見つかりません。") }
        var content = VisualContent.still
        if let length = asset.kind.videoDuration {
            let nextStart = layers.first { $0.slot == slot }?.clips.first { $0.start >= range.start }?.start ?? duration
            let limit = min(duration, nextStart, range.start + length)
            guard limit - range.start >= 1.0 / 30 else { throw StudioError.message("動画を配置する長さがありません。") }
            range.end = try grid.snap(limit, within: (range.start + 1.0 / 30)...limit)
            content = .video(sourceIn: 0)
        }
        var clip = VisualClip(assetID: assetID, start: range.start, end: range.end, content: content)
        if content.sourceIn != nil { clip.audioModulations = [:] }
        return (try inserting(clip, slot: slot, duration: duration), clip)
    }

    func inserting(_ clip: VisualClip, slot: Int, duration: Double) throws -> VisualTrack {
        var value = self
        guard let index = value.layers.firstIndex(where: { $0.slot == slot }) else { throw StudioError.message("素材レイヤーが見つかりません。") }
        value.layers[index].clips.append(clip)
        value.layers[index].clips.sort { $0.start < $1.start }
        try value.validate(duration: duration)
        return value
    }

    func updating(_ clip: VisualClip, slot: Int, duration: Double) throws -> VisualTrack {
        guard self.clip(clip.id) != nil else { throw StudioError.message("素材の配置が見つかりません。") }
        return try removingClip(id: clip.id).inserting(clip, slot: slot, duration: duration)
    }

    func removingClip(id: UUID) -> VisualTrack {
        var value = self
        for layer in value.layers.indices { value.layers[layer].clips.removeAll { $0.id == id } }
        return value
    }

    func dragging(id: UUID, part: TimelineDragPart, delta: Double, duration: Double, grid: TimelineSnapGrid) throws -> VisualTrack {
        try validate(duration: duration)
        guard delta.isFinite, let slot = slot(of: id), let layer = layers.first(where: { $0.slot == slot }), let index = layer.clips.firstIndex(where: { $0.id == id }) else { throw StudioError.message("素材の移動量が不正です。") }
        var clip = layer.clips[index]
        let before = index > 0 ? layer.clips[index - 1].end : 0
        let after = index + 1 < layer.clips.count ? layer.clips[index + 1].start : duration
        switch part {
        case .move:
            let start = try grid.snap(clip.start + delta, within: before...(min(after, duration) - (clip.end - clip.start)))
            clip.end += start - clip.start; clip.start = start
        case .start:
            let sourceStart = clip.content.sourceIn.map { clip.start - $0 } ?? 0
            clip.trimStart(to: try grid.snap(clip.start + delta, within: max(before, sourceStart)...(clip.end - 1.0 / 30)))
        case .end:
            let sourceEnd: Double
            if let sourceIn = clip.content.sourceIn, let length = asset(clip.assetID)?.kind.videoDuration {
                sourceEnd = clip.start + length - sourceIn
            } else { sourceEnd = duration }
            clip.end = try grid.snap(clip.end + delta, within: (clip.start + 1.0 / 30)...min(after, duration, sourceEnd))
        }
        return try updating(clip, slot: slot, duration: duration)
    }
}
