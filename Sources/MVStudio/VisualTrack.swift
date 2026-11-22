import Foundation

enum VisualAssetKind: Codable, Sendable, Equatable {
    case still
    case video(duration: Double)
    case spine(SpineAssetDescriptor)

    var spineDescriptor: SpineAssetDescriptor? { if case let .spine(value) = self { return value }; return nil }
    var title: String { switch self { case .still: return "画像"; case .video: return "動画"; case .spine: return "Spine" } }
    func sameType(as other: Self) -> Bool {
        switch (self, other) {
        case (.still, .still), (.video, .video), (.spine, .spine): return true
        default: return false
        }
    }
    func rebased(from source: URL, to destination: URL) -> Self {
        guard var descriptor = spineDescriptor else { return self }
        descriptor.atlasReference = AssetReference(url: descriptor.atlasReference.resolve(projectURL: source), projectURL: destination)
        return .spine(descriptor)
    }
    func accepts(_ content: VisualContent) -> Bool {
        switch (self, content) {
        case (.still, .still): return true
        case let (.video(duration), .video(sourceIn, speed)): return sourceIn >= 0 && speed > 0 && duration > 0
        case let (.spine(descriptor), .spine(playback)): return playback.isValid && playback.names.isSubset(of: Set(descriptor.animations.map(\.name)))
        default: return false
        }
    }

    var videoDuration: Double? { if case let .video(duration) = self { return duration }; return nil }
}

enum VisualContent: Codable, Sendable, Equatable {
    case still
    case video(sourceIn: Double, speed: Double = 1)
    case spine(SpinePlayback)

    var sourceIn: Double? {
        switch self { case .still: return nil; case let .video(value, _): return value; case let .spine(value): return value.sourceIn }
    }
    var speed: Double { if case let .video(_, speed) = self { return speed }; return 1 }
    var isVideo: Bool { if case .video = self { return true }; return false }
    var spinePlayback: SpinePlayback? { if case let .spine(value) = self { return value }; return nil }
    mutating func setSourceIn(_ value: Double) {
        switch self {
        case .still: break
        case let .video(_, speed): self = .video(sourceIn: value, speed: speed)
        case var .spine(playback): playback.sourceIn = value; self = .spine(playback)
        }
    }
}

struct VisualAsset: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var reference: AssetReference
    var kind: VisualAssetKind = .still
    var name: String { URL(fileURLWithPath: reference.path).lastPathComponent }
}

struct VisualClip: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var assetID: UUID?
    var start: Double
    var end: Double
    var content: VisualContent = .still
    private var baseAudioModulations: [ImageParameter: AudioModulation] = [:]
    private var baseAutomationRanges: [ImageParameter: DisplayRange] = [:]
    var fixedValues: [ImageParameter: Double] = [:]
    private var baseAutomations: [ParameterAutomation] = []
    var effects: ImageEffects?

    private enum CodingKeys: String, CodingKey {
        case id, assetID, start, end, content, fixedValues
        case baseAudioModulations = "audioModulations", baseAutomationRanges = "automationRanges", baseAutomations = "automations"
        case effects = "effectChain"
    }

    init(id: UUID = UUID(), assetID: UUID? = nil, start: Double, end: Double, content: VisualContent = .still,
         audioModulations: [ImageParameter: AudioModulation] = [:], automationRanges: [ImageParameter: DisplayRange] = [:],
         fixedValues: [ImageParameter: Double] = [:], curves: [ImageCurve] = [], effects: ImageEffects? = nil) {
        self.id = id; self.assetID = assetID; self.start = start; self.end = end; self.content = content
        self.fixedValues = fixedValues; self.effects = effects
        self.audioModulations = audioModulations; self.automationRanges = automationRanges; self.curves = curves
    }

    var automations: [ParameterAutomation] {
        get { baseAutomations + (effects?.allNodes.flatMap(\.automations) ?? []) }
        set {
            baseAutomations = newValue.filter { $0.parameter.effectKind == nil || effects?.node(for: $0.parameter) == nil }
            for node in effects?.allNodes ?? [] {
                effects?.editNode(node.id) { value in value.automations = newValue.filter { $0.parameter.effectKind == value.kind } }
            }
        }
    }
    var curves: [ImageCurve] {
        get { AutomationCurves.curves(automations, ranges: automationRanges) }
        set {
            var items = automations, ranges = automationRanges
            AutomationCurves.update(newValue, items: &items, ranges: &ranges)
            automations = items; automationRanges = ranges
        }
    }
    var audioModulations: [ImageParameter: AudioModulation] {
        get { (effects?.allNodes ?? []).reduce(baseAudioModulations) { $0.merging($1.audioModulations) { _, new in new } } }
        set {
            baseAudioModulations = newValue.filter { $0.key.effectKind == nil || effects?.node(for: $0.key) == nil }
            for node in effects?.allNodes ?? [] {
                effects?.editNode(node.id) { value in value.audioModulations = newValue.filter { $0.key.effectKind == value.kind } }
            }
        }
    }
    var automationRanges: [ImageParameter: DisplayRange] {
        get { (effects?.allNodes ?? []).reduce(baseAutomationRanges) { $0.merging($1.automationRanges) { _, new in new } } }
        set {
            baseAutomationRanges = newValue.filter { $0.key.effectKind == nil || effects?.node(for: $0.key) == nil }
            for node in effects?.allNodes ?? [] {
                effects?.editNode(node.id) { value in value.automationRanges = newValue.filter { $0.key.effectKind == value.kind } }
            }
        }
    }
    var hasValidAutomationStorage: Bool {
        baseAutomations.allSatisfy { $0.parameter.effectKind == nil }
            && baseAudioModulations.keys.allSatisfy { $0.effectKind == nil }
            && baseAutomationRanges.keys.allSatisfy { $0.effectKind == nil }
            && fixedValues.keys.allSatisfy { $0.effectKind == nil }
    }
    var orderedAutomationParameters: [ImageParameter] {
        let used = automationParameters
        let base = ImageParameter.allCases.filter { $0.effectKind == nil && used.contains($0) }
        return base + (effects?.allNodes ?? []).flatMap { node in
            ImageParameter.allCases.filter { $0.effectKind == node.kind && used.contains($0) }
        }
    }

    static let playbackSpeedRange = 0.1...16.0
    func sourceTime(at time: Double) -> Double {
        (content.sourceIn ?? 0) + (time - start) * content.speed
    }
    var sourceEnd: Double { sourceTime(at: end) }
}

struct VisualLayer: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var isVisible = true
    var isLocked = false
    var clips: [VisualClip] = []
}

struct VisualTrack: Codable, Sendable, Equatable {
    var assets: [VisualAsset] = []
    var layers: [VisualLayer] = (1...3).map { VisualLayer(name: "レイヤー \($0)") }
    var clips: [VisualClip] { layers.flatMap(\.clips) }
    func asset(_ id: UUID?) -> VisualAsset? { assets.first { $0.id == id } }
    func clip(_ id: UUID?) -> VisualClip? { clips.first { $0.id == id } }
    func layerID(of id: UUID) -> UUID? { layers.first { $0.clips.contains { $0.id == id } }?.id }
    func active(at time: Double) -> [VisualClip] {
        layers.filter(\.isVisible).flatMap { $0.clips.filter { $0.start <= time && time < $0.end } }
    }
    func uses(_ id: UUID) -> [VisualClip] { clips.filter { $0.assetID == id } }
    func particleUses(_ id: UUID) -> [VisualClip] { clips.filter { $0.particleAssetIDs.contains(id) } }

    func validate(duration: Double? = nil) throws {
        var ids = Set<UUID>()
        guard (1...Self.maximumLayers).contains(layers.count) else { throw StudioError.message("レイヤー数は1〜\(Self.maximumLayers)段にしてください。") }
        for asset in assets {
            guard ids.insert(asset.id).inserted, !asset.reference.path.isEmpty, asset.kind.spineDescriptor?.isValid != false, asset.kind.videoDuration.map({ $0.isFinite && $0 > 0 }) ?? true else { throw StudioError.message("素材素材の参照が不正です。") }
        }
        let assetIDs = Set(assets.map(\.id))
        for layer in layers {
            guard Self.validName(layer.name) else { throw StudioError.message("レイヤー名が不正です。") }
            guard ids.insert(layer.id).inserted else { throw StudioError.message("素材レイヤーのIDが重複しています。") }
            try LayerCrossfade.validate(layer.clips)
            for clip in layer.clips {
                guard ids.insert(clip.id).inserted, (clip.assetID.map { assetIDs.contains($0) } ?? (clip.content == .still)),
                      clip.start.isFinite, clip.end.isFinite, clip.start >= 0,
                      clip.end - clip.start >= 1.0 / 30 - 1e-9,
                      duration.map({ clip.end <= $0 + 1e-9 }) ?? true else {
                    throw StudioError.message("素材の区間は曲内に配置し、最小1フレームにしてください。")
                }
                switch (asset(clip.assetID)?.kind, clip.content) {
                case (nil, .still) where clip.assetID == nil: break
                case (.still, .still): break
                case let (.spine(descriptor), .spine):
                    guard descriptor.isValid, VisualAssetKind.spine(descriptor).accepts(clip.content) else { throw StudioError.message("Spineの設定が不正です。") }
                case let (.video(length), .video(sourceIn, speed)):
                    guard sourceIn.isFinite, sourceIn >= 0, speed.isFinite, VisualClip.playbackSpeedRange.contains(speed), clip.sourceEnd <= length + 1e-9 else {
                        throw StudioError.message("動画の速度は0.1〜16倍で、参照区間が素材の長さを超えないようにしてください。")
                    }
                default: throw StudioError.message("素材とクリップの種類が一致しません。")
                }
                for id in clip.particleAssetIDs {
                    guard let image = asset(id), image.kind == .still else { throw StudioError.message("粒子画像の素材参照が不正です。") }
                }
                for node in clip.effects?.allNodes ?? [] {
                    guard node.particleAppearance?.isValid != false,
                          node.particleAppearance == nil || node.kind.supportsParticleImage else { throw StudioError.message("粒子画像の設定が不正です。") }
                    guard ids.insert(node.id).inserted else { throw StudioError.message("演出ノードのIDが重複しています。") }
                }
                guard clip.effects?.isValid != false else { throw StudioError.message("素材クリップの追加演出の設定が不正です。") }
                if let playback = clip.content.spinePlayback {
                    try playback.validate()
                    for id in playback.keyIDs { guard ids.insert(id).inserted else { throw StudioError.message("制御点のIDが重複しています。") } }
                }
                try clip.validateAnimation(ids: &ids)
            }
        }
    }

    mutating func register(url: URL, projectURL: URL, kind: VisualAssetKind = .still) -> UUID {
        let kind = kind.rebased(from: projectURL, to: projectURL)
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
        try requireEditableAsset(id)
        guard let index = assets.firstIndex(where: { $0.id == id }) else { throw StudioError.message("素材が見つかりません。") }
        guard assets[index].kind.sameType(as: kind) else { throw StudioError.message("同じ種類の素材で置き換えてください。") }
        var value = self
        value.assets[index].kind = kind
        if let existing = assets.first(where: { $0.id != id && $0.reference.resolve(projectURL: projectURL).standardizedFileURL == url.standardizedFileURL }) {
            if let existingIndex = value.assets.firstIndex(where: { $0.id == existing.id }) { value.assets[existingIndex].kind = kind }
            for layer in value.layers.indices {
                for clip in value.layers[layer].clips.indices {
                    if value.layers[layer].clips[clip].assetID == id { value.layers[layer].clips[clip].assetID = existing.id }
                    value.layers[layer].clips[clip].remapParticleAsset(id, to: existing.id)
                }
            }
            value.assets.remove(at: index)
        } else { value.assets[index].reference = AssetReference(url: url.standardizedFileURL, projectURL: projectURL) }
        try value.validate()
        return value
    }

    func removingAsset(id: UUID, includingPlacements: Bool) throws -> VisualTrack {
        try requireEditableAsset(id)
        guard includingPlacements || (uses(id).isEmpty && particleUses(id).isEmpty) else { throw StudioError.message("使用中の素材です。配置も削除する確認が必要です。") }
        var value = self
        for layer in value.layers.indices { value.layers[layer].clips.removeAll { $0.assetID == id } }
        for layer in value.layers.indices {
            for clip in value.layers[layer].clips.indices { value.layers[layer].clips[clip].remapParticleAsset(id, to: nil) }
        }
        value.assets.removeAll { $0.id == id }
        try value.validate()
        return value
    }

    func placement(at time: Double, layerID: UUID, duration: Double, grid: TimelineSnapGrid) throws -> (start: Double, end: Double) {
        try requireEditable(layerID)
        guard time.isFinite, time >= 0, time < duration, layers.contains(where: { $0.id == layerID }) else { throw StudioError.message("曲の範囲内の素材行を選んでください。") }
        let start = try grid.snap(time, within: 0...duration)
        let limit = duration
        guard limit - start >= 1.0 / 30 - 1e-9 else { throw StudioError.message("素材を配置する空き時間がありません。") }
        let end = try grid.snap(min(start + 2, limit), within: (start + 1.0 / 30)...limit)
        return (start, end)
    }

    func adding(assetID: UUID, at time: Double, layerID: UUID, duration: Double, grid: TimelineSnapGrid) throws -> (track: VisualTrack, clip: VisualClip) {
        var range = try placement(at: time, layerID: layerID, duration: duration, grid: grid)
        guard let asset = asset(assetID) else { throw StudioError.message("素材が見つかりません。") }
        var content = VisualContent.still
        if let length = asset.kind.videoDuration {
            let limit = min(duration, range.start + length)
            guard limit - range.start >= 1.0 / 30 else { throw StudioError.message("動画を配置する長さがありません。") }
            range.end = try grid.snap(limit, within: (range.start + 1.0 / 30)...limit)
            content = .video(sourceIn: 0)
        }
        if let descriptor = asset.kind.spineDescriptor { content = .spine(SpinePlayback(animationName: descriptor.animations[0].name)) }
        let clip = VisualClip(assetID: assetID, start: range.start, end: range.end, content: content)
        return (try inserting(clip, layerID: layerID, duration: duration), clip)
    }

    func addingEmpty(at time: Double, layerID: UUID, duration: Double, grid: TimelineSnapGrid) throws -> (track: VisualTrack, clip: VisualClip) {
        let range = try placement(at: time, layerID: layerID, duration: duration, grid: grid)
        let clip = VisualClip(assetID: nil, start: range.start, end: range.end, effects: ImageEffects(solidBackground: .init()))
        return (try inserting(clip, layerID: layerID, duration: duration), clip)
    }

    func inserting(_ clip: VisualClip, layerID: UUID, duration: Double) throws -> VisualTrack {
        try requireEditable(layerID)
        var value = self
        guard let index = value.layers.firstIndex(where: { $0.id == layerID }) else { throw StudioError.message("素材レイヤーが見つかりません。") }
        value.layers[index].clips.append(clip)
        value.layers[index].clips.sort { $0.start < $1.start }
        try value.validate(duration: duration)
        return value
    }

    func updating(_ clip: VisualClip, layerID: UUID, duration: Double) throws -> VisualTrack {
        try requireEditable(self.layerID(of: clip.id))
        guard self.clip(clip.id) != nil else { throw StudioError.message("素材の配置が見つかりません。") }
        return try removingClip(id: clip.id).inserting(clip, layerID: layerID, duration: duration)
    }

    func removingClip(id: UUID) -> VisualTrack {
        var value = self
        for layer in value.layers.indices { value.layers[layer].clips.removeAll { $0.id == id } }
        return value
    }

    func dragging(id: UUID, part: TimelineDragPart, delta: Double, duration: Double, grid: TimelineSnapGrid) throws -> VisualTrack {
        try validate(duration: duration)
        guard delta.isFinite, let layerID = layerID(of: id), let layer = layers.first(where: { $0.id == layerID }), let index = layer.clips.firstIndex(where: { $0.id == id }) else { throw StudioError.message("素材の移動量が不正です。") }
        var clip = layer.clips[index]
        switch part {
        case .move:
            let start = try grid.snap(clip.start + delta, within: 0...(duration - (clip.end - clip.start)))
            clip.end += start - clip.start; clip.start = start
        case .start:
            let sourceStart = clip.content.sourceIn.map { clip.start - $0 / clip.content.speed } ?? 0
            clip.trimStart(to: try grid.snap(clip.start + delta, within: max(0, sourceStart)...(clip.end - 1.0 / 30)))
        case .end:
            let sourceEnd: Double
            if let sourceIn = clip.content.sourceIn, let length = asset(clip.assetID)?.kind.videoDuration {
                sourceEnd = clip.start + (length - sourceIn) / clip.content.speed
            } else { sourceEnd = duration }
            clip.end = try grid.snap(clip.end + delta, within: (clip.start + 1.0 / 30)...min(duration, sourceEnd))
        }
        return try updating(clip, layerID: layerID, duration: duration)
    }
}
