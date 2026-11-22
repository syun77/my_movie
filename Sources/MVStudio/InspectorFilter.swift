import AppKit

/// 保存された設定から判定し、再生中の評価値や表示範囲には依存しない。
enum InspectorFilter {
    static let defaultsKey = "clipInspectorModifiedOnly"

    static func differs(_ value: Double, from initial: Double) -> Bool {
        abs(value - initial) > max(1, abs(initial)) * 1e-9
    }

    static func isModified(_ parameter: ImageParameter, in clip: VisualClip) -> Bool {
        differs(clip.baseValue(parameter), from: parameter.defaultValue)
            || clip.automation(parameter) != nil || clip.audioModulations[parameter] != nil
    }
}

/// フィルターによる非表示だけを復元し、用途別の表示条件を保つ。
@MainActor
final class InspectorFilterVisibility {
    private var hidden: [NSView] = []

    func hide(_ view: NSView) {
        guard !view.isHidden else { return }
        hidden.append(view)
        view.isHidden = true
    }

    func restore() {
        hidden.forEach { $0.isHidden = false }
        hidden.removeAll()
    }
}
