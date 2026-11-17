import XCTest
@testable import MVStudio

final class OctgramsTests: XCTestCase {
    func testPersistenceAutomationAndTrim() throws {
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:], effects: ImageEffects(octgrams: .init()))
        for parameter in ImageEffects.Octgrams.parameters {
            let effect = try XCTUnwrap(parameter.effect)
            _ = clip.setKey(parameter, at: 1, value: effect.range.lowerBound)
            _ = clip.setKey(parameter, at: 3, value: effect.range.upperBound)
            XCTAssertTrue(clip.automationParameters.contains(parameter))
            XCTAssertEqual(effect.read(try XCTUnwrap(clip.evaluatedEffects(at: 2))), (effect.range.lowerBound + effect.range.upperBound) / 2)
        }
        clip.trimStart(to: 2)
        XCTAssertEqual(clip.effects?.octgrams?.phaseOffset, 1)
        XCTAssertEqual(try JSONDecoder().decode(VisualClip.self, from: JSONEncoder().encode(clip)), clip)
        XCTAssertTrue(clip.effects?.isValid == true)
        clip.effects?.octgrams?.zoom = 0
        XCTAssertFalse(clip.effects?.isValid == true)
    }

    func testRenderingSeekOpacityAndTrim() throws {
        let canvas = try EffectTestCanvas(scale: 0.25)
        var clip = canvas.clip
        clip.effects = ImageEffects(octgrams: .init())
        func pixels() -> [[UInt8]] {
            stride(from: 10, to: 270, by: 25).flatMap { y in
                stride(from: 10, to: 480, by: 25).map { canvas.pixel($0, y) }
            }
        }
        try canvas.draw([(clip, 0)], time: 0.5)
        let first = pixels()
        XCTAssertTrue(first.contains { $0[0] > 30 })
        try canvas.save("/tmp/my-movie-oct-preview.png")
        try canvas.draw([(clip, 0)], time: 1.5)
        XCTAssertNotEqual(first, pixels())
        try canvas.draw([(clip, 0)], time: 0.5)
        XCTAssertEqual(first, pixels())
        clip.trimStart(to: 0.25)
        try canvas.draw([(clip, 0)], time: 0.5)
        XCTAssertEqual(first, pixels())
        clip.effects?.octgrams?.opacity = 0
        try canvas.draw([(clip, 0)], time: 0.5)
        let hidden = pixels()
        clip.effects = nil
        try canvas.draw([(clip, 0)], time: 0.5)
        XCTAssertEqual(hidden, pixels())
    }
}
