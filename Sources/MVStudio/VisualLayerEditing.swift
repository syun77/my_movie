import Foundation

enum VisualLayerAction {
    case add(above: Bool), move(forward: Bool), rename, delete, visibility, lock
}

extension VisualTrack {
    // The limit also bounds decoding and render-plan allocations for untrusted project data.
    static let maximumLayers = 50
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && name.rangeOfCharacter(from: .newlines) == nil
    }
    func layer(_ id: UUID?) -> VisualLayer? { layers.first { $0.id == id } }
    var visibleClips: [VisualClip] { layers.filter(\.isVisible).flatMap(\.clips) }
    func canEdit(_ id: UUID?) -> Bool { layer(id).map { !$0.isLocked } ?? false }
    func requireEditable(_ id: UUID?) throws {
        guard canEdit(id) else { throw StudioError.message("レイヤーが存在しないかロックされています。ロックを解除してください。") }
    }
    func requireEditableAsset(_ id: UUID) throws {
        for layer in layers where layer.isLocked && layer.clips.contains(where: { $0.assetID == id || $0.particleAssetIDs.contains(id) }) {
            throw StudioError.message("「\(layer.name)」のロックを解除してください。")
        }
    }
    func validateEditing(from original: VisualTrack) throws {
        for old in original.layers where old.isLocked {
            guard let new = layer(old.id), new.name == old.name, new.isVisible == old.isVisible, new.clips == old.clips else {
                throw StudioError.message("「\(old.name)」のロックを解除してください。")
            }
        }
        for old in original.assets where asset(old.id) != old { try original.requireEditableAsset(old.id) }
    }
    func addingLayer(relativeTo id: UUID, above: Bool) throws -> (track: VisualTrack, id: UUID) {
        guard layers.count < Self.maximumLayers, let index = layers.firstIndex(where: { $0.id == id }) else {
            throw StudioError.message("レイヤーは最大\(Self.maximumLayers)段です。")
        }
        var n = 1
        while layers.contains(where: { $0.name == "レイヤー \(n)" }) { n += 1 }
        let layer = VisualLayer(name: "レイヤー \(n)")
        var result = self; result.layers.insert(layer, at: index + (above ? 1 : 0))
        return (result, layer.id)
    }
    func movingLayer(_ id: UUID, relativeTo target: UUID, above: Bool) throws -> VisualTrack {
        try requireEditable(id)
        guard id != target, let layer = layer(id), layers.contains(where: { $0.id == target }) else { return self }
        var result = self; result.layers.removeAll { $0.id == id }
        let index = result.layers.firstIndex { $0.id == target }!
        result.layers.insert(layer, at: index + (above ? 1 : 0))
        return result
    }
    func removingLayer(_ id: UUID) throws -> VisualTrack {
        try requireEditable(id)
        guard layers.count > 1 else { throw StudioError.message("最後のレイヤーは削除できません。") }
        var result = self; result.layers.removeAll { $0.id == id }; return result
    }
    func editingLayer(_ id: UUID, _ edit: (inout VisualLayer) -> Void) throws -> VisualTrack {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { throw StudioError.message("レイヤーが見つかりません。") }
        var result = self; edit(&result.layers[index]); try result.validateEditing(from: self); try result.validate(); return result
    }
    func renderPlacement(for clipID: UUID) -> (id: UUID, order: Int, maskOwner: UUID?)? {
        guard let index = layers.firstIndex(where: { $0.clips.contains { $0.id == clipID } }) else { return nil }
        let owner = index + 1 < layers.count ? layers[index + 1].id : nil
        return (layers[index].id, index, owner)
    }
}
