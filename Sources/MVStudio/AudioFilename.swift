import Foundation

enum AudioFilename {
    static func bpm(in url: URL) -> Double? {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"(?i)bpm([0-9]+(?:\.[0-9]+)?)(?![0-9.])|(?<![0-9.])([0-9]+(?:\.[0-9]+)?)bpm"#
        let expression = try! NSRegularExpression(pattern: pattern)
        for match in expression.matches(in: name, range: NSRange(name.startIndex..., in: name)) {
            guard let range = Range(match.range, in: name) else { continue }
            let token = String(name[range]).lowercased().replacingOccurrences(of: "bpm", with: "")
            if let value = Double(token), (20...300).contains(value) { return value }
        }
        return nil
    }
}
