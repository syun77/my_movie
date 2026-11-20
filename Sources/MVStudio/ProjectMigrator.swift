import Foundation

struct ProjectReadResult {
    let project: ProjectFile
    let sourceVersion: Int
    let originalData: Data
    let sourceURL: URL
    let changes: [String]
    var needsMigration: Bool { sourceVersion != ProjectFile.currentVersion }
}

enum ProjectFormatError: LocalizedError {
    case invalidVersion
    case tooOld(Int)
    case future(Int)
    case invalid(String)
    case changed

    var errorDescription: String? {
        switch self {
        case .invalidVersion: return "プロジェクトのversionが欠落しているか、整数ではありません。"
        case .tooOld(let version): return "形式v\(version)には対応していません。対応範囲はv\(ProjectFile.oldestSupportedVersion)〜v\(ProjectFile.currentVersion)です。"
        case .future(let version): return "形式v\(version)はこのアプリより新しい形式です。アプリを更新してください。"
        case .invalid(let path): return "プロジェクトの形式が不正、または変換できない項目があります: \(path)"
        case .changed: return "読み込み後にプロジェクトが変更されました。上書きせずに停止しました。再読み込みしてください。"
        }
    }
}

/// 旧形式の差分は読み込み境界で解消し、編集には現行モデルだけを渡す。
enum ProjectMigrator {
    private struct Header: Decodable { let version: Int }

    static func read(_ data: Data, at url: URL) throws -> ProjectReadResult {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProjectFormatError.invalid("JSON")
        }
        guard let version = try? JSONDecoder().decode(Header.self, from: data).version else {
            throw ProjectFormatError.invalidVersion
        }
        guard version >= ProjectFile.oldestSupportedVersion else { throw ProjectFormatError.tooOld(version) }
        guard version <= ProjectFile.currentVersion else { throw ProjectFormatError.future(version) }
        var changes: [String] = []
        if version < ProjectFile.currentVersion { try freezeLegacyDefaults(&root) }
        while let current = root["version"] as? Int, current < ProjectFile.currentVersion {
            switch current {
            case 13: try migrate13To14(&root)
            case 14: try migrate14To15(&root)
            case 15: try migrate15To16(&root)
            default: throw ProjectFormatError.invalid("version")
            }
            changes.append("v\(current) → v\(current + 1)")
            root["version"] = current + 1
        }
        let project: ProjectFile
        do {
            project = try JSONDecoder().decode(ProjectFile.self, from: JSONSerialization.data(withJSONObject: root))
        } catch let error as DecodingError {
            throw ProjectFormatError.invalid(decodingPath(error))
        }
        try project.validate()
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))
        try checkRetainedKeys(root, encoded, path: "project")
        return ProjectReadResult(project: project, sourceVersion: version, originalData: data, sourceURL: url, changes: changes)
    }

    private static func migrate15To16(_ root: inout [String: Any]) throws {
        try rejectPayloads(["electricBeam"], in: &root)
    }

    private static func migrate14To15(_ root: inout [String: Any]) throws {
        try rejectPayloads(["sobelChromatic", "fireOutline"], in: &root)
    }

    private static func rejectPayloads(_ kinds: [String], in root: inout [String: Any]) throws {
        try editClips(&root) { clip, path in
            let chain = clip["effectChain"] as? [String: Any]
            for node in chain?["nodes"] as? [[String: Any]] ?? [] {
                let payload = node["payload"] as? [String: Any] ?? [:]
                for kind in kinds where payload[kind] != nil {
                    throw ProjectFormatError.invalid(path + ".effectChain." + kind)
                }
            }
        }
    }

    private static func migrate13To14(_ root: inout [String: Any]) throws {
        guard var layers = root["visualLayers"] as? [[String: Any]], layers.count == 3,
              Set(layers.compactMap { $0["slot"] as? Int }) == Set(1...3) else { throw ProjectFormatError.invalid("visualLayers.slot") }
        layers.sort { ($0["slot"] as! Int) < ($1["slot"] as! Int) }
        var mapping: [String: String] = [:]
        for index in layers.indices {
            guard let id = layers[index]["id"] as? String, UUID(uuidString: id) != nil,
                  layers[index]["name"] == nil, layers[index]["isVisible"] == nil, layers[index]["isLocked"] == nil else { throw ProjectFormatError.invalid("visualLayers") }
            let slot = layers[index].removeValue(forKey: "slot") as! Int
            mapping[String(slot)] = id
            layers[index]["name"] = "レイヤー \(slot)"
            layers[index]["isVisible"] = true; layers[index]["isLocked"] = false
        }
        root["visualLayers"] = layers
        if var heights = root["timelineHeights"] as? [String: Any] {
            for key in ["visuals", "spine", "automation"] {
                guard let old = heights[key] as? [String: Any] else { continue }
                var pairs: [Any] = []
                for slot in old.keys.sorted() {
                    guard let id = mapping[slot] else { throw ProjectFormatError.invalid("timelineHeights." + key) }
                    pairs.append(id); pairs.append(old[slot]!)
                }
                heights[key] = pairs
            }
            root["timelineHeights"] = heights
        }
    }

    private static func editClips(_ root: inout [String: Any], edit: (inout [String: Any], String) throws -> Void) throws {
        guard var layers = root["visualLayers"] as? [[String: Any]] else { throw ProjectFormatError.invalid("visualLayers") }
        for i in layers.indices {
            guard var clips = layers[i]["clips"] as? [[String: Any]] else { throw ProjectFormatError.invalid("visualLayers[\(i)].clips") }
            for j in clips.indices { try edit(&clips[j], "visualLayers[\(i)].clips[\(j)]") }
            layers[i]["clips"] = clips
        }
        root["visualLayers"] = layers
    }

    private static func freezeLegacyDefaults(_ root: inout [String: Any]) throws {
        let layout: [String: Any] = ["x": 144, "y": 821, "width": 1632, "height": 216, "barGap": 28]
        if var settings = root["settings"] as? [String: Any] {
            var style = settings["spectrumStyle"] as? [String: Any]
            if settings["spectrumStyle"] == nil || settings["spectrumStyle"] is NSNull {
                style = ["shape": "bars", "color": ["red": 0.2, "green": 0.85, "blue": 0.95], "resolution": 32]
            }
            if var style {
                if style["layout"] == nil || style["layout"] is NSNull { style["layout"] = layout }
                settings["spectrumStyle"] = style
            }
            root["settings"] = settings
        }
        if var lyrics = root["lyrics"] as? [String: Any] {
            if lyrics["typography"] == nil || lyrics["typography"] is NSNull {
                lyrics["typography"] = ["fontName": "HiraginoSans-W6", "fontSize": 54, "x": 960, "y": 540]
            }
            root["lyrics"] = lyrics
        }
    }

    /// Codableが黙って捨てる未知の保存項目を検出する。辞書の交互配列は順序非依存で照合する。
    private static func checkRetainedKeys(_ input: Any, _ output: Any, path: String) throws {
        if let source = input as? [String: Any], let target = output as? [String: Any] {
            for (key, value) in source {
                guard let saved = target[key] else {
                    if value is NSNull { continue }
                    throw ProjectFormatError.invalid(path + "." + key)
                }
                try checkRetainedKeys(value, saved, path: path + "." + key)
            }
        } else if let source = input as? [Any], let target = output as? [Any] {
            guard source.count == target.count else { throw ProjectFormatError.invalid(path) }
            if source.count.isMultiple(of: 2), !source.isEmpty,
               stride(from: 0, to: source.count, by: 2).allSatisfy({ source[$0] is String && target[$0] is String }) {
                for i in stride(from: 0, to: source.count, by: 2) {
                    guard let j = stride(from: 0, to: target.count, by: 2).first(where: { target[$0] as? String == source[i] as? String }) else {
                        throw ProjectFormatError.invalid(path)
                    }
                    try checkRetainedKeys(source[i + 1], target[j + 1], path: path + ".\(source[i])")
                }
            } else {
                for i in source.indices { try checkRetainedKeys(source[i], target[i], path: path + "[\(i)]") }
            }
        }
    }

    private static func decodingPath(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .keyNotFound(let key, let value): return (value.codingPath + [key]).map(\.stringValue).joined(separator: ".")
        case .typeMismatch(_, let value), .valueNotFound(_, let value), .dataCorrupted(let value): context = value
        @unknown default: return "JSON"
        }
        return context.codingPath.map(\.stringValue).joined(separator: ".") + " (" + context.debugDescription + ")"
    }
}
