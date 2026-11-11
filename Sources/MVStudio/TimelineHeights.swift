import Foundation

struct TimelineHeights: Codable, Equatable {
    enum Row: Equatable {
        case lyrics
        case visual(Int)
        case automation(Int, ImageParameter)

        var defaultHeight: Double {
            switch self {
            case .lyrics: return 44
            case .visual: return 46
            case .automation: return 62
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .lyrics: return 20...400
            case .visual: return 21...400
            case .automation: return 27...400
            }
        }
    }

    static let viewportRange: ClosedRange<Double> = 112...10_000
    var viewport: Double?
    private var lyrics: Double?
    private var visuals: [Int: Double] = [:]
    private var automation: [Int: [ImageParameter: Double]] = [:]

    subscript(row: Row) -> Double {
        get {
            let height: Double?
            switch row {
            case .lyrics: height = lyrics
            case .visual(let slot): height = visuals[slot]
            case .automation(let slot, let parameter): height = automation[slot]?[parameter]
            }
            return height ?? row.defaultHeight
        }
        set {
            let height = newValue == row.defaultHeight ? nil : newValue
            switch row {
            case .lyrics: lyrics = height
            case .visual(let slot): visuals[slot] = height
            case .automation(let slot, let parameter):
                var lanes = automation[slot] ?? [:]
                lanes[parameter] = height
                automation[slot] = lanes.isEmpty ? nil : lanes
            }
        }
    }

    var isValid: Bool {
        (viewport.map(Self.viewportRange.contains) ?? true)
            && Row.lyrics.range.contains(self[.lyrics])
            && visuals.allSatisfy { (1...3).contains($0.key) && Row.visual($0.key).range.contains($0.value) }
            && automation.allSatisfy { slot, lanes in
                (1...3).contains(slot) && lanes.allSatisfy { Row.automation(slot, $0.key).range.contains($0.value) }
            }
    }
}
