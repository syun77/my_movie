import AppKit
import Metal
import XCTest
@testable import MVStudio

final class ShapeTests: XCTestCase {
    func testValidationPersistenceAutomationAndTrim() throws {
        var clip = VisualClip(assetID: nil, start: 1, end: 5, audioModulations: [:],
                              effects: ImageEffects(shape: .init(), mask: .init(target: .below)))
        for parameter in [ImageParameter.shapeWidth, .shapeHeight, .shapeX, .shapeY, .shapeRotation, .shapeInnerRatio,
                          .shapeOpacity, .maskWidth, .maskHeight, .maskX, .maskY, .maskRotation, .maskInnerRatio,
                          .maskFeather, .maskStrength] {
            let range = parameter.defaultRange
            _ = clip.setKey(parameter, at: 1, value: range.lowerBound)
            _ = clip.setKey(parameter, at: 3, value: range.upperBound)
            let evaluated = try XCTUnwrap(clip.evaluatedEffects(at: 2))
            XCTAssertEqual(try XCTUnwrap(parameter.effect?.read(evaluated)), (range.lowerBound + range.upperBound) / 2, accuracy: 1e-8)
        }
        let before = clip.evaluatedEffects(at: 2.5)
        clip.trimStart(to: 2)
        XCTAssertEqual(clip.evaluatedEffects(at: 2.5), before)
        XCTAssertTrue(clip.curves.allSatisfy { $0.keys.first?.time == -1 })
        var track = VisualTrack()
        track.layers[2].clips = [clip]
        try track.validate(duration: 6)
        let url = URL(fileURLWithPath: "/tmp/shape.mvproject")
        let project = ProjectFile(audioURL: URL(fileURLWithPath: "/tmp/song.wav"), visuals: track, settings: SceneSettings(), projectURL: url)
        let data = try JSONEncoder().encode(project)
        let restored = try JSONDecoder().decode(ProjectFile.self, from: data)
        try restored.validate()
        XCTAssertEqual(restored.version, 10)
        XCTAssertEqual(restored.visuals, track)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["version"] = 9
        XCTAssertThrowsError(try JSONDecoder().decode(ProjectFile.self, from: JSONSerialization.data(withJSONObject: old)).validate())
        var geometry = ShapeGeometry()
        for kind in ShapeGeometry.Kind.allCases { geometry.kind = kind; XCTAssertTrue(geometry.isValid) }
        geometry.width = .infinity
        XCTAssertFalse(geometry.isValid)
        geometry.width = 0; geometry.points = 4.5
        XCTAssertFalse(geometry.isValid)
        geometry.points = 5; geometry.innerRatio = .nan
        XCTAssertFalse(geometry.isValid)
        clip.effects?.mask?.strength = -1
        XCTAssertEqual(clip.effects?.isValid, false)
    }

    @MainActor
    func testEditorShapeColorCopyTargetAndRemoval() throws {
        _ = NSApplication.shared
        let editor = ImageEffectsEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        editor.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(editor)
        NSLayoutConstraint.activate([editor.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                                     editor.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                                     editor.topAnchor.constraint(equalTo: root.topAnchor, constant: -8)])
        defer { window.close() }
        var clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:], effects: ImageEffects(solidBackground: .init()))
        var track = VisualTrack()
        let lower = VisualClip(assetID: nil, start: 0, end: 1)
        func load() { track.layers[0].clips = [lower]; track.layers[1].clips = [clip]; editor.load(clip, editable: true, track: track) }
        load()
        editor.onCommit = { clip.effects = $0; load() }
        func all(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(all) }
        func button(_ title: String) throws -> NSButton { try XCTUnwrap(all(editor).compactMap { $0 as? NSButton }.first { $0.title == title }) }
        func click(_ button: NSButton) { XCTAssertTrue(button.sendAction(button.action, to: button.target)) }
        let add = try XCTUnwrap(all(editor).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.add" })
        func addEffect(_ title: String) throws {
            let item = try XCTUnwrap(add.menu?.item(withTitle: title))
            XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        click(try button("▸ 追加演出"))
        try addEffect("図形")
        XCTAssertNotNil(clip.effects?.shape)
        let notice = try button("単色背景が有効")
        XCTAssertFalse(notice.isHidden)
        notice.state = .off; click(notice)
        XCTAssertEqual(clip.effects?.solidBackground?.isEnabled, false)
        let color = try XCTUnwrap(all(editor).compactMap { $0 as? NSColorWell }.first { $0.identifier?.rawValue == "visuals.effects.shapeColor" })
        color.activate(true)
        NSColorPanel.shared.color = .red
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(clip.effects?.shape?.color, RGBColor(red: 1, green: 0, blue: 0))
        color.deactivate(); NSColorPanel.shared.orderOut(nil)
        try addEffect("マスク")
        clip.effects?.shape?.geometry.kind = .star
        clip.effects?.shape?.geometry.width = 700
        load()
        click(try button("図形をマスクへコピー"))
        XCTAssertEqual(clip.effects?.mask?.geometry, clip.effects?.shape?.geometry)
        root.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/my-movie-mask-inspector.png"))
        clip.effects?.shape?.geometry.width = 900; load()
        XCTAssertEqual(clip.effects?.mask?.geometry.width, 700)
        let target = try XCTUnwrap(all(editor).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "visuals.effects.maskTarget" })
        XCTAssertEqual(target.item(at: 1)?.isEnabled, true)
        target.selectItem(at: 1); XCTAssertTrue(target.sendAction(target.action, to: target.target))
        XCTAssertEqual(clip.effects?.mask?.target, .below)
        editor.time = 1.5
        XCTAssertTrue(all(editor).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("対象なし") })
        track.layers[1].clips = []; track.layers[0].clips = [clip]; editor.load(clip, editable: true, track: track)
        XCTAssertEqual(target.item(at: 1)?.isEnabled, false)
        XCTAssertEqual(clip.effects?.mask?.target, .below)
        click(try button("削除"))
        XCTAssertNil(clip.effects?.mask)
        XCTAssertNotNil(clip.effects?.shape)
    }

    func testGeometryAndSelfMaskPixels() throws {
        let render = try Canvas()
        var clip = render.clip
        clip.effects = ImageEffects(shape: .init(geometry: ShapeGeometry(width: 600, height: 200, x: 600, y: 300), color: RGBColor(red: 1, green: 0, blue: 0)))
        try render.draw([(clip, 1)])
        XCTAssertGreaterThan(render.pixel(600, 300)[2], 250)
        XCTAssertLessThan(render.pixel(600, 780)[2], 20)
        XCTAssertLessThan(render.pixel(600, 430)[2], 20)
        clip.effects?.shape?.geometry.rotation = 90
        try render.draw([(clip, 1)])
        XCTAssertGreaterThan(render.pixel(600, 500)[2], 250)
        XCTAssertLessThan(render.pixel(800, 300)[2], 20)
        for kind in ShapeGeometry.Kind.allCases {
            clip.effects?.shape?.geometry = ShapeGeometry(kind: kind, width: 600, height: 600)
            try render.draw([(clip, 1)])
            XCTAssertGreaterThan(render.pixel(960, 540)[2], 250, kind.title)
            XCTAssertLessThan(render.pixel(640, 220)[2], 20, kind.title)
            if kind == .triangle {
                XCTAssertGreaterThan(render.pixel(710, 800)[2], 250)
                XCTAssertLessThan(render.pixel(710, 300)[2], 20)
            }
            if kind == .star {
                try render.save("/tmp/my-movie-star-preview.png")
                XCTAssertGreaterThan(render.pixel(960, 270)[2], 250)
                XCTAssertLessThan(render.pixel(1110, 280)[2], 20)
            }
        }
        clip.effects?.shape?.geometry.width = 0
        try render.draw([(clip, 1)])
        XCTAssertLessThan(render.pixel(960, 540)[2], 20)
        clip.effects = ImageEffects(mask: .init(geometry: ShapeGeometry(kind: .ellipse)), solidBackground: .init(color: .white), bloom: .init())
        try render.draw([(clip, 1)])
        XCTAssertGreaterThan(render.pixel(960, 540)[0], 250)
        XCTAssertLessThan(render.pixel(1500, 540)[0], 25)
        clip.effects?.mask?.inverted = true
        try render.draw([(clip, 1)])
        XCTAssertLessThan(render.pixel(960, 540)[0], 25)
        XCTAssertGreaterThan(render.pixel(1500, 540)[0], 250)
        clip.effects?.mask?.inverted = false
        clip.effects?.mask?.strength = 0
        try render.draw([(clip, 1)])
        XCTAssertGreaterThan(render.pixel(1500, 540)[0], 250)
        clip.effects?.mask?.strength = 100; clip.effects?.mask?.feather = 100
        try render.draw([(clip, 1)])
        XCTAssertGreaterThan(render.pixel(1170, 540)[0], 25)
        XCTAssertLessThan(render.pixel(1170, 540)[0], 250)
        clip.effects?.mask?.geometry.width = 0
        try render.draw([(clip, 1)])
        XCTAssertLessThan(render.pixel(960, 540)[0], 25)
        clip.effects?.mask?.inverted = true
        try render.draw([(clip, 1)])
        XCTAssertGreaterThan(render.pixel(960, 540)[0], 250)
    }

    func testPreviewScaleGuidesAnimatedCacheAndMaskChain() throws {
        let full = try Canvas()
        let half = try Canvas(scale: 0.5)
        var back = full.clip
        back.effects = ImageEffects(solidBackground: .init(color: RGBColor(red: 0, green: 0, blue: 1)))
        var middle = full.clip; middle.id = UUID()
        middle.effects = ImageEffects(mask: .init(geometry: ShapeGeometry(width: 0), target: .below),
                                      solidBackground: .init(color: RGBColor(red: 1, green: 0, blue: 0)))
        var upper = full.clip; upper.id = UUID()
        upper.effects = ImageEffects(mask: .init(geometry: ShapeGeometry(kind: .ellipse), target: .below))
        try full.draw([])
        let background = full.pixel(100, 100)
        let layers = [(back, 1), (middle, 2), (upper, 3)]
        try full.draw(layers); try half.draw(layers)
        XCTAssertGreaterThan(full.pixel(960, 540)[2], 250)
        XCTAssertEqual(full.pixel(100, 100), background, "両マスクは独立して直下段だけを切り抜く")
        for (x, y) in [(960, 540), (100, 100), (960, 200)] {
            for channel in 0..<3 { XCTAssertEqual(Double(full.pixel(x, y)[channel]), Double(half.pixel(x / 2, y / 2)[channel]), accuracy: 2) }
        }
        upper.effects?.mask?.target = .image
        upper.effects?.mask?.strength = 0
        try full.draw([(upper, 3)])
        let noGuide = full.pixel(1160, 540)
        try full.draw([(upper, 3)], guide: upper.id)
        XCTAssertNotEqual(full.pixel(1160, 540), noGuide)
        try full.draw([(upper, 3)], video: true)
        let exported = full.pixel(1160, 540)
        try full.draw([(upper, 3)], guide: upper.id, video: true)
        XCTAssertEqual(full.pixel(1160, 540), exported)
        upper.effects?.mask?.target = .below
        upper.effects?.mask?.strength = 100
        _ = upper.setKey(.maskX, at: 0, value: 500)
        _ = upper.setKey(.maskX, at: 1, value: 1400)
        middle.effects?.mask = nil
        try full.draw([(middle, 2), (upper, 3)], time: 0)
        XCTAssertGreaterThan(full.pixel(500, 540)[2], 250)
        XCTAssertLessThan(full.pixel(1400, 540)[2], 20)
        try full.draw([(middle, 2), (upper, 3)], time: 1)
        XCTAssertLessThan(full.pixel(500, 540)[2], 20)
        XCTAssertGreaterThan(full.pixel(1400, 540)[2], 250)
        try full.draw([(middle, 2), (upper, 3)], time: 0)
        XCTAssertGreaterThan(full.pixel(500, 540)[2], 250)
        XCTAssertLessThan(full.pixel(1400, 540)[2], 20)
        back.effects?.snow = .init(seed: 42)
        back.effects?.orbs = .init()
        middle.effects?.mask = .init(geometry: ShapeGeometry(kind: .star, width: 1200, height: 900), target: .below, feather: 20)
        middle.effects?.particles = .init(seed: 42)
        upper.effects?.orbs = .init()
        var encoding: [Double] = [], gpu: [Double] = []
        for index in 0..<9 {
            try full.draw([(back, 1), (middle, 2), (upper, 3)], time: Double(index) / 8)
            encoding.append(full.lastEncodeMS); gpu.append(full.lastGPUMS)
        }
        print("SHAPES_3x1080_MASK_PARTICLES encode_max_ms=\(encoding.max() ?? 0) gpu_max_ms=\(gpu.max() ?? 0)")
    }

    func testBelowMaskIsolationOpacityParticlesAndTiming() throws {
        let render = try Canvas()
        var back = render.clip
        back.effects = ImageEffects(solidBackground: .init(color: RGBColor(red: 0, green: 0, blue: 1)))
        var lower = render.clip; lower.id = UUID()
        lower.effects = ImageEffects(solidBackground: .init(color: RGBColor(red: 1, green: 0, blue: 0)))
        var owner = render.clip; owner.id = UUID()
        owner.effects = ImageEffects(mask: .init(geometry: ShapeGeometry(kind: .ellipse), target: .below))
        try render.draw([(back, 1), (lower, 2), (owner, 3)])
        XCTAssertGreaterThan(render.pixel(960, 540)[2], 250)
        XCTAssertGreaterThan(render.pixel(100, 100)[0], 250)
        XCTAssertLessThan(render.pixel(100, 100)[2], 5)
        owner.fixedValues[.opacity] = 0
        try render.draw([(back, 1), (lower, 2), (owner, 3)])
        XCTAssertGreaterThan(render.pixel(100, 100)[2], 250)
        owner.fixedValues[.opacity] = 50
        try render.draw([(back, 1), (lower, 2), (owner, 3)])
        XCTAssertEqual(Double(render.pixel(100, 100)[2]), 188, accuracy: 3)
        XCTAssertEqual(Double(render.pixel(100, 100)[0]), 188, accuracy: 3)
        owner.fixedValues[.opacity] = 100
        try render.draw([(back, 1), (owner, 3)])
        XCTAssertGreaterThan(render.pixel(960, 540)[0], 250)
        XCTAssertGreaterThan(render.pixel(100, 100)[0], 250)
        owner.end = 0.5
        try render.draw([(back, 1), (lower, 2), (owner, 3)], time: 0.5)
        XCTAssertGreaterThan(render.pixel(100, 100)[2], 250)
        owner.end = 2
        lower.effects = ImageEffects(particles: .init(seed: 42), snow: .init(seed: 42), orbs: .init())
        try render.draw([(back, 1), (lower, 2)])
        let samples = stride(from: 100, to: 1900, by: 130).flatMap { x in stride(from: 100, to: 1000, by: 110).map { (x, $0) } }
        let baseline = samples.map { render.pixel($0.0, $0.1) }
        owner.effects?.mask?.strength = 0
        try render.draw([(back, 1), (lower, 2), (owner, 3)])
        for (index, point) in samples.enumerated() {
            for channel in 0..<3 { XCTAssertEqual(Double(render.pixel(point.0, point.1)[channel]), Double(baseline[index][channel]), accuracy: 2) }
        }
        owner.effects?.mask?.strength = 100; owner.effects?.mask?.geometry.width = 0
        try render.draw([(back, 1), (lower, 2), (owner, 3)])
        for point in samples { XCTAssertEqual(render.pixel(point.0, point.1), [255, 0, 0, 255]) }
        lower.effects?.mask = .init(geometry: ShapeGeometry(width: 0))
        try render.draw([(back, 1), (lower, 2)])
        XCTAssertTrue(samples.contains { render.pixel($0.0, $0.1) != [255, 0, 0, 255] }, "自画像マスクは粒子を切らない")
    }
}

private final class Canvas {
    private(set) var lastEncodeMS = 0.0
    private(set) var lastGPUMS = 0.0
    let renderer: MetalSceneRenderer
    let target: MTLTexture
    let transparent: CGImage
    let clip = VisualClip(assetID: nil, start: 0, end: 2, audioModulations: [:])
    init(scale: Double = 1) throws {
        renderer = try MetalSceneRenderer(scale: scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(1920 * scale), height: Int(1080 * scale), mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                            space: MetalSceneRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        transparent = try XCTUnwrap(context.makeImage())
    }
    func draw(_ clips: [(VisualClip, Int)], time: Double = 0.5, guide: UUID? = nil, video: Bool = false) throws {
        let layers = clips.map { clip, slot -> VisualRenderLayer in
            var layer = VisualRenderLayer(clip: clip, image: transparent); layer.slot = slot; return layer
        }
        let begin = ProcessInfo.processInfo.systemUptime
        let commands = try renderer.encode(visuals: layers, features: nil, settings: SceneSettings(spectrum: false), lyrics: LyricsTrack(), time: time, target: target, video: video, guideClipID: guide)
        lastEncodeMS = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        commands.commit(); commands.waitUntilCompleted()
        lastGPUMS = (commands.gpuEndTime - commands.gpuStartTime) * 1000
        if commands.status != .completed { throw commands.error ?? MetalSceneRenderer.renderError }
    }
    func save(_ path: String) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: target.width, height: target.height, bitsPerComponent: 8, bytesPerRow: target.width * 4,
                                            space: MetalSceneRenderer.sRGB,
                                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        target.getBytes(try XCTUnwrap(context.data), bytesPerRow: context.bytesPerRow,
                        from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4)
        target.getBytes(&result, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return result
    }
}
