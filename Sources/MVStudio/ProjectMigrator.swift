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
            case 17: try migrate17To18(&root)
            case 18: try migrate18To19(&root)
            case 19: try migrate19To20(&root)
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

    private static func migrate19To20(_ root: inout [String: Any]) throws {
        try rejectParameters(["spiralGlowWidth", "spiralGlowStrength"], in: root)
        try editClips(&root) { clip, path in
            guard var chain = clip["effectChain"] as? [String: Any],
                  var nodes = chain["nodes"] as? [[String: Any]] else { return }
            for index in nodes.indices {
                guard var payload = nodes[index]["payload"] as? [String: Any],
                      var wrapped = payload["spiralParticles"] as? [String: Any],
                      var value = wrapped["_0"] as? [String: Any] else { continue }
                guard value["glowWidth"] == nil && value["glowStrength"] == nil else {
                    throw ProjectFormatError.invalid(path + ".effectChain.spiralParticles.glow")
                }
                value["glowWidth"] = 0; value["glowStrength"] = 100
                wrapped["_0"] = value; payload["spiralParticles"] = wrapped; nodes[index]["payload"] = payload
            }
            chain["nodes"] = nodes; clip["effectChain"] = chain
        }
    }

    private static func migrate18To19(_ root: inout [String: Any]) throws {
        try rejectPayloads(["spiralParticles"], in: &root)
        let parameters = Set(ImageParameter.allCases.filter { $0.effectKind == .spiralParticles }.map(\.rawValue))
        try rejectParameters(parameters, in: root)
    }

    private static func migrate17To18(_ root: inout [String: Any]) throws {
        func convert(_ object: inout [String: Any], path: String) throws {
            guard object["automations"] == nil else { throw ProjectFormatError.invalid(path + ".automations") }
            guard let curves = object.removeValue(forKey: "curves") as? [[String: Any]],
                  var ranges = object["automationRanges"] as? [Any], ranges.count.isMultiple(of: 2) else {
                throw ProjectFormatError.invalid(path + ".curves/automationRanges")
            }
            var automations: [[String: Any]] = []
            for curve in curves {
                guard let parameter = curve["parameter"] as? String, let keys = curve["keys"] as? [Any],
                      let minimum = curve["minimum"], let maximum = curve["maximum"],
                      Set(curve.keys).isSubset(of: ["parameter", "keys", "minimum", "maximum"]) else {
                    throw ProjectFormatError.invalid(path + ".curves")
                }
                guard !stride(from: 0, to: ranges.count, by: 2).contains(where: { ranges[$0] as? String == parameter }) else {
                    throw ProjectFormatError.invalid(path + ".automationRanges")
                }
                ranges += [parameter, ["lower": minimum, "upper": maximum]]
                automations.append(["parameter": parameter, "mode": "keys", "keyCurve": ["keys": keys]])
            }
            object["automations"] = automations
            object["automationRanges"] = ranges
        }
        try editClips(&root) { clip, path in
            try convert(&clip, path: path)
            if var chain = clip["effectChain"] as? [String: Any] {
                if var nodes = chain["nodes"] as? [[String: Any]] {
                    for index in nodes.indices { try convert(&nodes[index], path: path + ".effectChain.nodes[\(index)]") }
                    chain["nodes"] = nodes
                }
                if var mask = chain["outputMask"] as? [String: Any] {
                    try convert(&mask, path: path + ".effectChain.outputMask"); chain["outputMask"] = mask
                }
                clip["effectChain"] = chain
            }
        }
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

    private static func rejectParameters(_ parameters: Set<String>, in value: Any, path: String = "project", parameterContext: Bool = false) throws {
        if let object = value as? [String: Any] {
            let collections: Set<String> = ["fixedValues", "audioModulations", "automationRanges", "automation", "nodeAutomation"]
            for (key, child) in object {
                if parameterContext && parameters.contains(String(key.split(separator: "/").last ?? "")) {
                    throw ProjectFormatError.invalid(path + "." + key)
                }
                try rejectParameters(parameters, in: child, path: path + "." + key,
                                     parameterContext: parameterContext || key == "parameter" || collections.contains(key))
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                try rejectParameters(parameters, in: child, path: path + "[\(index)]", parameterContext: parameterContext)
            }
        } else if parameterContext, let name = value as? String,
                  parameters.contains(String(name.split(separator: "/").last ?? "")) {
            throw ProjectFormatError.invalid(path)
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
