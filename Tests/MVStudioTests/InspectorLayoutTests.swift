import AppKit
import XCTest
@testable import MVStudio

final class InspectorLayoutTests: XCTestCase {
    @MainActor func testSectionsFitInspectorAndKeepConditionalDetails() throws {
        _ = NSApplication.shared
        let visual = VisualEditor(); _ = visual.view
        var track = VisualTrack()
        let clip = VisualClip(start: 0, end: 5)
        track.layers[0].clips = [clip]
        let timeline = TimelineView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        visual.timeline = timeline
        visual.duration = 10
        visual.load(track, projectURL: nil)
        visual.setAvailable(true)
        timeline.onImageSelect?(clip.id, track.layers[0].id)
        let lyrics = LyricsEditor(); _ = lyrics.view
        let spectrum = SpectrumEditor(); _ = spectrum.view
        for (name, root, expected) in [("visual", visual.view, 4), ("lyrics", lyrics.view, 4), ("spectrum", spectrum.view, 2)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 1800), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            defer { window.close() }
            let container = NSView()
            window.contentView = container
            container.addSubview(root)
            root.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                root.topAnchor.constraint(equalTo: container.topAnchor),
                root.widthAnchor.constraint(equalToConstant: 450)
            ])
            container.layoutSubtreeIfNeeded()
            let sections = root.subviews.compactMap { $0 as? InspectorSection }
            XCTAssertEqual(sections.count, expected, name)
            for section in sections {
                XCTAssertEqual(section.frame.width, 450, accuracy: 1, name)
                XCTAssertGreaterThan(section.frame.height, 24, name)
                for row in section.arrangedSubviews where !row.isHidden {
                    XCTAssertGreaterThanOrEqual(row.alignmentRect(forFrame: row.frame).minX, 11, name)
                    XCTAssertLessThanOrEqual(row.alignmentRect(forFrame: row.frame).maxX, 439, name)
                }
            }
            func checkControls(_ view: NSView) {
                guard !view.isHidden else { return }
                if view is NSControl {
                    let frame = root.convert(view.alignmentRect(forFrame: view.frame), from: view.superview)
                    XCTAssertGreaterThanOrEqual(frame.minX, -1, name + ": " + (view.identifier?.rawValue ?? "control"))
                    XCTAssertLessThanOrEqual(frame.maxX, 451, name + ": " + (view.identifier?.rawValue ?? "control"))
                }
                if view is NSScrollView { return }
                view.subviews.forEach(checkControls)
            }
            checkControls(root)
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let snapshot = NSImage(size: root.bounds.size, flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                bitmap.draw(in: rect)
                return true
            }
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(snapshot.tiffRepresentation))?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/my-movie-inspector-" + name + ".png"))
            root.removeFromSuperview()
        }
        let lfoAmount = try XCTUnwrap(DragValueField.fields(in: visual.view).first { $0.identifier?.rawValue == "lfo.amount" })
        XCTAssertTrue(lfoAmount.isHiddenOrHasHiddenAncestor)
    }
}
