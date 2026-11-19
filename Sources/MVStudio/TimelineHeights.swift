import Foundation

struct TimelineHeights: Codable, Equatable {
    enum Row: Equatable {
        case lyrics
        case visual(UUID)
        case automation(UUID, ImageParameter)
        case spine(UUID)

        var defaultHeight: Double {
            switch self {
            case .lyrics: return 44
            case .visual: return 46
            case .automation: return 62
            case .spine: return 80
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .lyrics: return 20...400
            case .visual: return 21...400
            case .automation: return 27...400
            case .spine: return 80...100_000
            }
        }
    }

    static let viewportRange: ClosedRange<Double> = 112...10_000
    var viewport: Double?
    private var lyrics: Double?
    private var visuals: [UUID: Double] = [:]
    private var spine: [UUID: Double] = [:]
    private var nodeAutomation: [String: Double]?
    private var automation: [UUID: [ImageParameter: Double]] = [:]

    subscript(row: Row) -> Double {
        get {
            let height: Double?
            switch row {
            case .lyrics: height = lyrics
            case .visual(let layerID): height = visuals[layerID]
            case .spine(let layerID): height = spine[layerID]
            case .automation(let layerID, let parameter): height = automation[layerID]?[parameter]
            }
            return height ?? row.defaultHeight
        }
        set {
            let height = newValue == row.defaultHeight ? nil : newValue
            switch row {
            case .lyrics: lyrics = height
            case .visual(let layerID): visuals[layerID] = height
            case .spine(let layerID): spine[layerID] = height
            case .automation(let layerID, let parameter):
                var lanes = automation[layerID] ?? [:]
                lanes[parameter] = height
                automation[layerID] = lanes.isEmpty ? nil : lanes
            }
        }
    }

    private func nodeKey(_ id: UUID, _ parameter: ImageParameter) -> String { id.uuidString + "/" + parameter.rawValue }
    func height(_ row: Row, nodeID: UUID?) -> Double {
        guard case let .automation(_, parameter) = row, let nodeID else { return self[row] }
        return nodeAutomation?[nodeKey(nodeID, parameter)] ?? self[row]
    }
    mutating func setHeight(_ height: Double, for row: Row, nodeID: UUID?) {
        guard case let .automation(_, parameter) = row, let nodeID else { self[row] = height; return }
        var values = nodeAutomation ?? [:]
        values[nodeKey(nodeID, parameter)] = height
        nodeAutomation = values.isEmpty ? nil : values
    }

    var isValid: Bool {
        (nodeAutomation?.allSatisfy { key, value in
            let parts = key.split(separator: "/")
            return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil
                && ImageParameter(rawValue: String(parts[1]))?.effectKind != nil && Row.automation(UUID(), .x).range.contains(value)
        } ?? true) && (viewport.map(Self.viewportRange.contains) ?? true)
            && Row.lyrics.range.contains(self[.lyrics])
            && visuals.allSatisfy { Row.visual($0.key).range.contains($0.value) }
            && spine.allSatisfy { Row.spine($0.key).range.contains($0.value) }
            && automation.allSatisfy { layerID, lanes in
                lanes.allSatisfy { Row.automation(layerID, $0.key).range.contains($0.value) }
            }
    }
}
