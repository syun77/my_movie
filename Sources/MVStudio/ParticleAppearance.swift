import Foundation

struct ParticleAppearance: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable { case standard, image }
    enum ColorMode: String, Codable, CaseIterable { case original, effect }
    enum Blend: String, Codable, CaseIterable { case normal, additive }
    var mode: Mode = .standard
    var assetID: UUID?
    var size = 32.0
    var angle = 0.0
    var spread = 0.0
    var spin = 0.0
    var colorMode: ColorMode = .original
    var blend: Blend = .normal
    var usesImage: Bool { mode == .image && assetID != nil }
    init() {}
    private enum CodingKeys: String, CodingKey { case mode, assetID, size, angle, spread, spin, colorMode, blend }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        assetID = try c.decodeIfPresent(UUID.self, forKey: .assetID)
        size = try c.decode(Double.self, forKey: .size)
        angle = try c.decode(Double.self, forKey: .angle)
        spread = try c.decode(Double.self, forKey: .spread)
        spin = try c.decode(Double.self, forKey: .spin)
        colorMode = try c.decode(ColorMode.self, forKey: .colorMode)
        blend = try c.decode(Blend.self, forKey: .blend)
        if assetID == nil { mode = .standard }
    }
    var isValid: Bool {
        (1...1000).contains(size) && (-180...180).contains(angle)
            && (0...180).contains(spread) && (-360...360).contains(spin)
    }
}

extension EffectKind {
    var supportsParticleImage: Bool { [.particles, .embers, .snow, .orbs, .spiralParticles].contains(self) }
}

extension ImageEffects {
    func appearance(_ kind: EffectKind) -> ParticleAppearance? {
        guard kind.supportsParticleImage, let node = nodes.first(where: { $0.kind == kind }) else { return nil }
        return node.particleAppearance ?? ParticleAppearance()
    }
    mutating func setAppearance(_ value: ParticleAppearance, for kind: EffectKind) {
        guard let id = nodes.first(where: { $0.kind == kind })?.id else { return }
        var value = value
        if value.assetID == nil { value.mode = .standard }
        editNode(id) { $0.particleAppearance = value }
    }
}

extension VisualClip {
    var particleAssetIDs: Set<UUID> {
        Set((effects?.nodes ?? []).compactMap { $0.particleAppearance?.assetID })
    }
    var activeParticleAssetIDs: Set<UUID> {
        guard effects?.isBypassed != true else { return [] }
        return Set((effects?.nodes ?? []).filter { $0.isEnabled && $0.particleAppearance?.usesImage == true }
            .compactMap { $0.particleAppearance?.assetID })
    }
    mutating func remapParticleAsset(_ id: UUID, to replacement: UUID?) {
        for node in effects?.nodes ?? [] where node.particleAppearance?.assetID == id {
            effects?.editNode(node.id) {
                $0.particleAppearance?.assetID = replacement
                if replacement == nil { $0.particleAppearance?.mode = .standard }
            }
        }
    }
}
