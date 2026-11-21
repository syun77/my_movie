import AppKit

/// Presentation groups for finding effects; processing order belongs to the chain.
enum EffectCategory: String, CaseIterable {
    case color = "色・質感"
    case blur = "ぼかし・発光"
    case particles = "粒子・天候"
    case lines = "効果線"
    case motion = "動き・抽象映像"
    case geometry = "背景・図形・マスク"

    var kinds: [EffectKind] {
        switch self {
        case .color: return [.colorCorrection, .binarization, .vignette, .chromaticAberration, .sobelChromatic]
        case .blur: return [.blur, .radialBlur, .bloom, .crossGlare, .lensFlare, .fireOutline]
        case .particles: return [.particles, .orbs, .spiralParticles, .embers, .snow]
        case .lines: return [.focusLines, .radialFocus, .sharpFocus, .straightLines, .radialRays, .electricBeam]
        case .motion: return [.shake, .zoomLoop, .octgrams, .warpFlight]
        case .geometry: return [.solidBackground, .gradientBackground, .shape, .mask]
        }
    }

    @MainActor static func additionMenu(effects: ImageEffects, editable: Bool,
                                        perform: @escaping (EffectKind) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for category in allCases {
            let complete = category.kinds.allSatisfy { $0.exists(in: effects) }
            let parent = NSMenuItem(title: category.rawValue + (complete ? "（すべて追加済み）" : ""), action: nil, keyEquivalent: "")
            parent.tag = -1
            parent.isEnabled = editable
            let submenu = NSMenu(title: category.rawValue)
            submenu.autoenablesItems = false
            for kind in category.kinds {
                let exists = kind.exists(in: effects)
                let item = EffectMenuItem(kind.title + (exists ? "（追加済み）" : ""), enabled: editable && !exists) { perform(kind) }
                item.tag = kind.rawValue
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        return menu
    }
}
