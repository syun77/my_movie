import Foundation
import Metal

enum SceneShaders {
    static func library(device: MTLDevice) throws -> MTLLibrary {
        let resources = Bundle.main.url(forResource: "MVStudio_MVStudio", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? .module
        guard let url = resources.url(forResource: "Scene", withExtension: "metal", subdirectory: "Shaders") else { throw StudioError.message("描画シェーダーを読み込めません。") }
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }
}
