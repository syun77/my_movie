import Foundation

extension LyricsTrack {
    func adding(at time: Double, duration: Double) throws -> (track: LyricsTrack, clip: LyricClip) {
        guard time.isFinite, time >= 0, time < duration else {
            throw StudioError.message("曲の範囲内に再生位置を合わせてください。")
        }
        var parent = clips.first { $0.start <= time && time < $0.end }
        while let current = parent, let next = clips.first(where: { $0.predecessorID == current.id }) { parent = next }
        let begin = parent?.end ?? time
        let limit = clips.first(where: { $0.start >= begin && $0.id != parent?.id })?.start ?? duration
        guard min(limit, duration) - begin >= 1.0 / 30 - 1e-9 else {
            throw StudioError.message("テロップを追加する空き時間がありません。")
        }
        let clip = LyricClip(start: begin, end: min(begin + 2, limit, duration), text: "歌詞を入力", predecessorID: parent?.id)
        var value = self
        value.clips.append(clip); value.clips.sort { $0.start < $1.start }
        try value.validate(duration: duration)
        return (value, clip)
    }

    func updating(id: UUID, start: Double, end: Double, text: String, duration: Double) throws -> LyricsTrack {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { throw StudioError.message("歌詞が見つかりません。") }
        var value = self
        let original = clips[index]
        let moved = start != original.start
        value.clips[index].start = start
        value.clips[index].end = moved && end == original.end ? end + (start - original.start) : end
        value.clips[index].text = text
        if moved { value.clips[index].predecessorID = nil }
        return try value.followingChains(duration: duration)
    }

    func settingChain(id: UUID, enabled: Bool, duration: Double) throws -> LyricsTrack {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { throw StudioError.message("歌詞が見つかりません。") }
        var value = self
        if enabled {
            guard index > 0 else { throw StudioError.message("先頭のテロップには連結できません。") }
            value.clips[index].predecessorID = clips[index - 1].id
        } else {
            value.clips[index].predecessorID = nil
        }
        return try value.followingChains(duration: duration)
    }

    func removing(id: UUID, duration: Double) throws -> LyricsTrack {
        var value = self
        value.clips.removeAll { $0.id == id }
        for index in value.clips.indices where value.clips[index].predecessorID == id { value.clips[index].predecessorID = nil }
        try value.validate(duration: duration)
        return value
    }

    func dragging(id: UUID, part: TimelineDragPart, delta: Double, duration: Double) throws -> LyricsTrack {
        try validate(duration: duration)
        guard delta.isFinite, let index = clips.firstIndex(where: { $0.id == id }) else {
            throw StudioError.message("テロップの移動量が不正です。")
        }
        let clip = clips[index]
        let minimumLength = 1.0 / 30
        var tail = index
        while tail + 1 < clips.count, clips[tail + 1].predecessorID == clips[tail].id { tail += 1 }
        let previousEnd = index > 0 ? clips[index - 1].end : 0
        let nextStart = tail + 1 < clips.count ? clips[tail + 1].start : duration
        let limit = min(duration, nextStart)
        let lower: Double
        let upper: Double
        switch part {
        case .move:
            lower = previousEnd - clip.start; upper = limit - clips[tail].end
        case .start:
            lower = previousEnd - clip.start; upper = clip.end - minimumLength - clip.start
        case .end:
            lower = clip.start + minimumLength - clip.end; upper = limit - clips[tail].end
        }
        let offset = max(lower, min(upper, (delta * 30).rounded() / 30))
        guard abs(offset) > 1e-9 else { return self }
        var value = self
        switch part {
        case .move:
            value.clips[index].start += offset; value.clips[index].end += offset
            value.clips[index].predecessorID = nil
        case .start:
            value.clips[index].start += offset; value.clips[index].predecessorID = nil
        case .end:
            value.clips[index].end += offset
        }
        return try value.followingChains(duration: duration)
    }

    private func followingChains(duration: Double) throws -> LyricsTrack {
        let lookup = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        var resolved = [UUID: LyricClip]()
        var visiting = Set<UUID>()
        func resolve(_ id: UUID) throws -> LyricClip {
            if let cached = resolved[id] { return cached }
            guard var clip = lookup[id], visiting.insert(id).inserted else {
                throw StudioError.message("テロップの連結先が不正です。")
            }
            if let parentID = clip.predecessorID {
                let length = clip.end - clip.start
                let parent = try resolve(parentID)
                clip.start = parent.end; clip.end = parent.end + length
            }
            visiting.remove(id); resolved[id] = clip
            return clip
        }
        var value = self
        value.clips = try clips.map { try resolve($0.id) }.sorted { $0.start < $1.start }
        try value.validate(duration: duration)
        return value
    }
}
