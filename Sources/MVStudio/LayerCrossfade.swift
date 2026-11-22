import Foundation

/// A transition is derived entirely from two ordered clip intervals.
struct LayerCrossfade: Equatable {
    let outgoingID: UUID
    let incomingID: UUID
    let start: Double
    let end: Double
    var duration: Double { end - start }

    init?(_ outgoing: VisualClip, _ incoming: VisualClip) {
        guard outgoing.start < incoming.start, incoming.start < outgoing.end, outgoing.end < incoming.end else { return nil }
        outgoingID = outgoing.id; incomingID = incoming.id
        start = incoming.start; end = outgoing.end
    }

    func incomingWeight(at time: Double) -> Double {
        let u = min(1, max(0, (time - start) / duration))
        return u * u * (3 - 2 * u)
    }

    static func transitions(in clips: [VisualClip]) -> [Self] {
        zip(clips, clips.dropFirst()).compactMap { Self($0, $1) }
    }

    static func validate(_ clips: [VisualClip]) throws {
        for index in clips.indices where index > 0 {
            let previous = clips[index - 1], clip = clips[index]
            guard previous.start < clip.start else {
                throw StudioError.message("同じレイヤーのクリップは開始時刻を異なる順番にしてください。")
            }
            if previous.end > clip.start {
                guard previous.end < clip.end else {
                    throw StudioError.message("クリップを完全に含む重なりや、終了時刻が同じ重なりは配置できません。")
                }
                guard index < 2 || clips[index - 2].end <= clip.start else {
                    throw StudioError.message("同じレイヤーで3クリップが同時に重なります。")
                }
            }
        }
    }
}
