import AppKit
import XCTest

enum SpineTestFixtures {
    static func make() throws -> (URL, URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spine-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = dir.appendingPathComponent("model.json")
        let atlas = dir.appendingPathComponent("separate.atlas")
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
            to: dir.appendingPathComponent("page.png"))
        try "page.png\nsize:4,4\nfilter:Linear,Linear\npma:true\nwhite\nbounds:0,0,4,4\n".write(
            to: atlas, atomically: true, encoding: .utf8)
        let root: [String: Any] = [
            "skeleton": ["spine": "4.3.26", "width": 200, "height": 100],
            "bones": [["name": "root"], ["name": "child", "parent": "root"]],
            "slots": [
                ["name": "clip", "bone": "child", "attachment": "clip"],
                ["name": "shape", "bone": "child", "attachment": "shape"],
                ["name": "after", "bone": "root", "attachment": "after"],
            ],
            "skins": [
                [
                    "name": "default",
                    "attachments": [
                        "clip": [
                            "clip": [
                                "type": "clipping", "end": "shape", "vertexCount": 6,
                                "vertices": [0, 0, 100, 0, 100, 40, 40, 40, 40, 100, 0, 100],
                            ]
                        ],
                        "shape": ["shape": ["path": "white", "x": 50, "y": 50, "width": 100, "height": 100]],
                        "after": ["after": ["path": "white", "x": 150, "y": 50, "width": 100, "height": 100]],
                    ],
                ]
            ],
            "animations": [
                "move": ["bones": ["child": ["translatex": [["value": 0], ["time": 1, "value": 10]]]]],
                "rotate": ["bones": ["child": ["rotate": [["value": 0], ["time": 1, "value": 90]]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: .sortedKeys).write(to: json)
        return (dir, json, atlas)
    }

}
