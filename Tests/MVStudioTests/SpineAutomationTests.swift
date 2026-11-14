import AppKit
import XCTest

@testable import MVStudio

final class SpineAutomationTests: XCTestCase {
    private func track(_ json: URL, descriptor: SpineAssetDescriptor, playback: SpinePlayback) -> VisualTrack {
        var track = VisualTrack()
        let id = track.register(
            url: json, projectURL: URL(fileURLWithPath: "/tmp/audio.mvproject"), kind: .spine(descriptor))
        track.layers[0].clips = [
            VisualClip(assetID: id, start: 2, end: 6, content: .spine(playback), audioModulations: [:])
        ]
        return track
    }
    private func packet(_ provider: SpinePoseProvider, track: VisualTrack, time: Double) async throws -> SpineDrawPacket
    {
        let layers = try await provider.layers(
            track: track, projectURL: URL(fileURLWithPath: "/tmp/audio.mvproject"), time: time, cancellation: nil)
        guard case .spine(let packet) = try XCTUnwrap(layers.first).source else {
            throw StudioError.message("Missing packet")
        }
        return packet
    }
    func testNamedHoldEvaluationTrimAndModeConversion() throws {
        var playback = SpinePlayback(animationName: "A", sourceIn: 1)
        let first = SpineAnimationKey(time: 0.5, animationName: "B")
        playback.mode = .selection(base: "A", keys: [first, SpineAnimationKey(time: 2, animationName: "A")])
        XCTAssertEqual(playback.resolved(at: 0.49).animation, "A")
        XCTAssertEqual(playback.resolved(at: 0.5).animation, "B")
        XCTAssertEqual(playback.resolved(at: 1.9).animation, "B")
        try playback.createBlend(minimum: "A", maximum: "B")
        guard case .blend(let blend) = playback.mode else { return XCTFail() }
        XCTAssertEqual(blend.weight(at: 0.49), 0)
        XCTAssertEqual(blend.weight(at: 0.5), 1)
        XCTAssertEqual(blend.weight(at: 1.9), 1)
        XCTAssertEqual(blend.weight(at: 2), 0)
        XCTAssertEqual(blend.keys[0].id, first.id)
        let oldIDs = playback.keyIDs
        playback.renewKeyIDs()
        XCTAssertTrue(Set(oldIDs).isDisjoint(with: playback.keyIDs))
        playback.trim(by: 1)
        XCTAssertEqual(playback.resolved(at: 0).weight, 1)
        playback.removeLane(at: 0.25)
        XCTAssertFalse(playback.hasLane)
        XCTAssertEqual(playback.mode, .single("B"))
        var three = SpinePlayback(animationName: "A")
        three.mode = .selection(
            base: "A",
            keys: [SpineAnimationKey(time: 0, animationName: "B"), SpineAnimationKey(time: 1, animationName: "C")])
        let original = three
        XCTAssertThrowsError(try three.createBlend(minimum: "A", maximum: "B"))
        XCTAssertEqual(three, original)
    }
    func testBlendCurveBoundsDefaultsAndSharedInterpolation() throws {
        var blend = SpineBlend(minimumAnimation: "A", maximumAnimation: "B", baseWeight: 0.25)
        blend.keys = [ImageKeyframe(time: 1, value: 0, midpointOffset: 2), ImageKeyframe(time: 3, value: 1)]
        XCTAssertEqual(blend.weight(at: 0), 0.25)
        XCTAssertEqual(blend.weight(at: 1), 0)
        XCTAssertEqual(blend.weight(at: 2), 1)
        XCTAssertEqual(blend.weight(at: 3), 1)
        for sample in blend.samples(from: 0, through: 4, steps: 200) { XCTAssertTrue((0...1).contains(sample.value)) }
        for interpolation in ImageInterpolation.allCases {
            blend.keys[1].interpolation = interpolation
            for time in stride(from: 1.0, through: 3, by: 0.025) {
                XCTAssertTrue((0...1).contains(blend.weight(at: time)))
            }
        }
        blend.keys[1].interpolation = .hold
        XCTAssertNil(blend.curve.midpoint(after: blend.keys[0].id))
        blend.keys[1].interpolation = nil
        XCTAssertNotNil(blend.curve.midpoint(after: blend.keys[0].id))
    }
    func testSharedClockAndIndependentPoseBlend() async throws {
        let (dir, json, atlas) = try SpineTestFixtures.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = SpinePoseProvider()
        let (descriptor, _) = try await provider.inspect(skeleton: json, atlas: atlas)
        var a = SpinePlayback(animationName: "move", sourceIn: 0.25, loop: false)
        var b = SpinePlayback(animationName: "rotate", sourceIn: 0.25, loop: false)
        let pa = try await packet(provider, track: track(json, descriptor: descriptor, playback: a), time: 2.75)
        let pb = try await packet(provider, track: track(json, descriptor: descriptor, playback: b), time: 2.75)
        a.mode = .selection(base: "move", keys: [SpineAnimationKey(time: 0.5, animationName: "rotate")])
        let selected = try await packet(provider, track: track(json, descriptor: descriptor, playback: a), time: 2.75)
        XCTAssertEqual(selected.vertices.map(\.x), pb.vertices.map(\.x))
        XCTAssertEqual(selected.vertices.map(\.y), pb.vertices.map(\.y))
        b.mode = .blend(
            SpineBlend(minimumAnimation: "move", maximumAnimation: "rotate", baseWeight: 0, automated: false))
        let zero = try await packet(provider, track: track(json, descriptor: descriptor, playback: b), time: 2.75)
        XCTAssertEqual(zero.vertices.map(\.x), pa.vertices.map(\.x))
        b.mode = .blend(
            SpineBlend(minimumAnimation: "move", maximumAnimation: "rotate", baseWeight: 1, automated: false))
        let one = try await packet(provider, track: track(json, descriptor: descriptor, playback: b), time: 2.75)
        XCTAssertEqual(one.vertices.map(\.x), pb.vertices.map(\.x))
        b.sourceIn = 0
        b.mode = .blend(
            SpineBlend(minimumAnimation: "move", maximumAnimation: "rotate", baseWeight: 0.5, automated: false))
        let half = try await packet(provider, track: track(json, descriptor: descriptor, playback: b), time: 2.5)
        XCTAssertTrue(
            half.vertices.contains { abs($0.x - 2.5) < 0.001 && abs($0.y) < 0.001 },
            "A-only translation must fade to setup while B rotation fades in")
        let angle = Float.pi / 8
        XCTAssertTrue(
            half.vertices.contains {
                abs($0.x - (2.5 + 100 * cos(angle))) < 0.01 && abs($0.y + 100 * sin(angle)) < 0.01
            }, "The runtime uses Y-down world coordinates")
        _ = try await packet(provider, track: track(json, descriptor: descriptor, playback: b), time: 3.9)
        let back = try await packet(provider, track: track(json, descriptor: descriptor, playback: b), time: 2.5)
        XCTAssertEqual(back.vertices.map(\.x), half.vertices.map(\.x))
    }
    func testRotationShortestPathAndExactOppositeTie() async throws {
        let (dir, json, atlas) = try SpineTestFixtures.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        root["animations"] = [
            "a": ["bones": ["child": ["rotate": [["value": 170]]]]],
            "b": ["bones": ["child": ["rotate": [["value": -170]]]]],
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: json)
        let provider = SpinePoseProvider()
        let (descriptor, _) = try await provider.inspect(skeleton: json, atlas: atlas)
        var playback = SpinePlayback(animationName: "a")
        playback.mode = .blend(
            SpineBlend(minimumAnimation: "a", maximumAnimation: "b", baseWeight: 0.5, automated: false))
        let pose = try await packet(provider, track: track(json, descriptor: descriptor, playback: playback), time: 2.5)
        XCTAssertTrue(
            pose.vertices.contains { abs($0.x + 100) < 0.01 && abs($0.y) < 0.01 }, "170 to -170 must pass through 180")
    }
    @MainActor func testStorageTrimHistoryAndDuplicateIDs() throws {
        let descriptor = SpineAssetDescriptor(
            atlasReference: AssetReference(
                url: URL(fileURLWithPath: "/tmp/a.atlas"), projectURL: URL(fileURLWithPath: "/tmp/audio.mvproject")),
            exportVersion: "4.3.26", referenceBounds: SpineBounds(x: 0, y: 0, width: 100, height: 100),
            animations: [SpineAnimation(name: "A", duration: 4), SpineAnimation(name: "B", duration: 4)])
        var playback = SpinePlayback(animationName: "A", sourceIn: 1)
        playback.mode = .selection(
            base: "A",
            keys: [SpineAnimationKey(time: 0.5, animationName: "B"), SpineAnimationKey(time: 2, animationName: "A")])
        let original = track(URL(fileURLWithPath: "/tmp/a.json"), descriptor: descriptor, playback: playback)
        var clip = original.clips[0]
        clip.trimStart(to: 3)
        let trimmed = try original.updating(clip, slot: 1, duration: 10)
        XCTAssertEqual(clip.sourceTime(at: 3.5), original.clips[0].sourceTime(at: 3.5))
        XCTAssertEqual(clip.content.spinePlayback?.resolved(at: 0.5), playback.resolved(at: 1.5))
        guard case .selection(_, let keys) = clip.content.spinePlayback?.mode else { return XCTFail() }
        XCTAssertEqual(keys[0].time, -0.5)
        let file = ProjectFile(
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"), visuals: trimmed, settings: SceneSettings(),
            projectURL: URL(fileURLWithPath: "/tmp/audio.mvproject"))
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(file))
        try decoded.validate()
        XCTAssertEqual(decoded.version, ProjectFile.currentVersion)
        XCTAssertEqual(decoded.visuals, trimmed)
        let history = EditHistory()
        history.reset(EditSnapshot(lyrics: LyricsTrack(), visuals: original, settings: SceneSettings()))
        history.record(EditSnapshot(lyrics: LyricsTrack(), visuals: trimmed, settings: SceneSettings()))
        XCTAssertEqual(history.undo()?.visuals, original)
        XCTAssertEqual(history.redo()?.visuals, trimmed)
        var duplicate = trimmed.clips[0]
        duplicate.id = UUID()
        duplicate.start = 6
        duplicate.end = 9
        XCTAssertThrowsError(try trimmed.inserting(duplicate, slot: 1, duration: 10))
        var copied = try XCTUnwrap(duplicate.content.spinePlayback)
        copied.renewKeyIDs()
        duplicate.content = .spine(copied)
        XCTAssertNoThrow(try trimmed.inserting(duplicate, slot: 1, duration: 10))
        var missing = playback
        missing.mode = .selection(base: "A", keys: [SpineAnimationKey(time: -1, animationName: "missing")])
        var invalid = original.clips[0]
        invalid.content = .spine(missing)
        XCTAssertThrowsError(try original.updating(invalid, slot: 1, duration: 10))
    }

    @MainActor func testBlendLaneBendInterpolationAndSingleRemoval() async throws {
        let (dir, json, atlas) = try SpineTestFixtures.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (descriptor, _) = try await SpinePoseProvider().inspect(skeleton: json, atlas: atlas)
        var playback = SpinePlayback(animationName: "move")
        playback.mode = .blend(
            SpineBlend(
                minimumAnimation: "move", maximumAnimation: "rotate",
                keys: [ImageKeyframe(time: 0, value: 0), ImageKeyframe(time: 2, value: 1)]))
        var current = track(json, descriptor: descriptor, playback: playback)
        current.layers[0].clips[0].start = 0
        current.layers[0].clips[0].end = 4
        let timeline = TimelineView(frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        let window = NSWindow(contentRect: timeline.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = timeline
        defer {
            timeline.onImageCommit = nil
            window.close()
        }
        timeline.visualMode = true
        timeline.duration = 5
        timeline.visibleSpan = 5
        timeline.visuals = current
        timeline.selectedImageID = current.clips[0].id
        timeline.selectedSlot = 1
        timeline.isEnabled = true
        timeline.revealAutomation(in: 1)
        var commits = 0
        var seeks = 0
        timeline.onSeek = { _ in seeks += 1 }
        timeline.onImageCommit = { value, _ in
            current = value
            timeline.visuals = value
            commits += 1
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let midpoint = CGPoint(x: timeline.x(at: 1), y: 226)
        let bent = CGPoint(x: timeline.x(at: 1), y: 216)
        timeline.mouseDown(with: event(.leftMouseDown, midpoint))
        timeline.mouseDragged(with: event(.leftMouseDragged, bent))
        timeline.mouseUp(with: event(.leftMouseUp, bent))
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(seeks, 0)
        XCTAssertEqual(current.clips[0].content.spinePlayback?.resolved(at: 1).weight ?? 0, 0.65625, accuracy: 0.001)
        let menu = try XCTUnwrap(timeline.menu(for: event(.rightMouseDown, CGPoint(x: timeline.x(at: 2), y: 194))))
        let hold = try XCTUnwrap(menu.items.first(where: { $0.title == "ホールド" }))
        _ = (hold.target as? NSObject)?.perform(try XCTUnwrap(hold.action), with: hold)
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(current.clips[0].content.spinePlayback?.resolved(at: 1).weight, 0)
        if let bitmap = timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds) {
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/tmp/my-movie-spine-blend-lane.png"))
        }
        let editor = PlacementEditor()
        _ = editor.view
        editor.restoreTab(.visuals)
        editor.duration = 5
        playback.mode = .blend(
            SpineBlend(
                minimumAnimation: "move", maximumAnimation: "rotate",
                keys: [ImageKeyframe(time: 0, value: 0), ImageKeyframe(time: 2, value: 1)]))
        current.layers[0].clips[0].content = .spine(playback)
        editor.visuals.load(current, projectURL: URL(fileURLWithPath: "/tmp/audio.mvproject"))
        editor.setAvailable(hasAudio: true, isBusy: false)
        editor.timeline.onImageSelect?(current.clips[0].id, 1)
        editor.currentTime = 0.75
        editor.visuals.editSpineLane(.remove)
        let fixed = try XCTUnwrap(editor.visuals.track.clips[0].content.spinePlayback)
        XCTAssertFalse(fixed.hasLane)
        XCTAssertEqual(fixed.mode, .single("move"))
        XCTAssertEqual(fixed.sourceIn, playback.sourceIn)
        XCTAssertEqual(fixed.loop, playback.loop)
        XCTAssertEqual(editor.currentTime, 0.75)
        func find(_ view: NSView, _ id: String) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find($0, id) }.first
        }
        let animation = try XCTUnwrap(find(editor.inspector, "visual.spine.animation") as? NSPopUpButton)
        let maximum = try XCTUnwrap(find(editor.inspector, "visual.spine.maximum"))
        let weight = try XCTUnwrap(find(editor.inspector, "visual.spine.weight"))
        XCTAssertEqual(animation.titleOfSelectedItem, "move")
        XCTAssertTrue(maximum.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(weight.isHiddenOrHasHiddenAncestor)
        let deleted = editor.visuals.track
        editor.visuals.restore(current)
        XCTAssertFalse(maximum.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(weight.isHiddenOrHasHiddenAncestor)
        editor.visuals.restore(deleted)
        XCTAssertTrue(maximum.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(weight.isHiddenOrHasHiddenAncestor)
        var maximumPlayback = playback
        maximumPlayback.removeLane(at: 1)
        XCTAssertEqual(maximumPlayback.mode, .single("rotate"))
        editor.visuals.setAvailable(false)
    }

    @MainActor func testCategoricalLaneClickDragCancelMenuAndDelete() throws {
        let descriptor = SpineAssetDescriptor(
            atlasReference: AssetReference(
                url: URL(fileURLWithPath: "/tmp/a.atlas"), projectURL: URL(fileURLWithPath: "/tmp/a.mvproject")),
            exportVersion: "4.3.26", referenceBounds: SpineBounds(x: 0, y: 0, width: 100, height: 100),
            animations: [SpineAnimation(name: "A", duration: 4), SpineAnimation(name: "B", duration: 4)])
        var playback = SpinePlayback(animationName: "A")
        playback.createSelection()
        var current = track(URL(fileURLWithPath: "/tmp/a.json"), descriptor: descriptor, playback: playback)
        current.layers[0].clips[0].start = 0
        current.layers[0].clips[0].end = 4
        let timeline = TimelineView(frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        let window = NSWindow(contentRect: timeline.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = timeline
        defer {
            timeline.onImageCommit = nil
            window.close()
        }
        timeline.visualMode = true
        timeline.duration = 5
        timeline.visibleSpan = 5
        timeline.visuals = current
        timeline.selectedImageID = current.clips[0].id
        timeline.selectedSlot = 1
        timeline.isEnabled = true
        timeline.revealAutomation(in: 1)
        var seeks = 0
        var commits = 0
        timeline.onSeek = { _ in seeks += 1 }
        timeline.onImageCommit = { value, _ in
            current = value
            timeline.visuals = value
            commits += 1
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: timeline.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Layer 1 follows two 46pt rows; its animation row spans y194...258.
        let point = CGPoint(x: timeline.x(at: 1), y: 258)
        timeline.mouseDown(with: event(.leftMouseDown, point))
        timeline.mouseUp(with: event(.leftMouseUp, point))
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(seeks, 0)
        XCTAssertEqual(current.clips[0].content.spinePlayback?.resolved(at: 1).animation, "B")
        if let bitmap = timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds) {
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/tmp/my-movie-spine-selection-lane.png"))
        }
        let menu = try XCTUnwrap(timeline.menu(for: event(.rightMouseDown, CGPoint(x: 20, y: 220))))
        XCTAssertEqual(menu.items.map(\.title), ["アニメーション切替", "2つのアニメーションでブレンド", "レーンを削除"])
        let keyMenu = try XCTUnwrap(timeline.menu(for: event(.rightMouseDown, point)))
        XCTAssertEqual(keyMenu.items.map(\.title), ["削除"])
        timeline.mouseDown(with: event(.leftMouseDown, point))
        timeline.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: timeline.x(at: 2), y: 194)))
        timeline.cancelDrag()
        XCTAssertEqual(commits, 1)
        timeline.mouseDown(with: event(.leftMouseDown, point))
        timeline.mouseUp(with: event(.leftMouseUp, point))
        let delete = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        timeline.keyDown(with: delete)
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(current.clips[0].content.spinePlayback?.keyIDs, [])
    }
}
