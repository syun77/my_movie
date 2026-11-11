import AppKit

enum ClipEditCommand: String, CaseIterable {
    case cut = "x"
    case copy = "c"
    case paste = "v"
    case duplicate = "d"
    case delete

    var title: String {
        switch self {
        case .cut: return "切り取り"
        case .copy: return "コピー"
        case .paste: return "貼り付け"
        case .duplicate: return "複製"
        case .delete: return "削除"
        }
    }
}

enum ClipClipboard: Codable {
    case lyrics(LyricClip)
    case visual(VisualClip, assetURL: URL, kind: VisualAssetKind = .still)

    private static let type = NSPasteboard.PasteboardType("local.mymovie.mvstudio.clip")

    static func read(from pasteboard: NSPasteboard) -> Self? {
        guard let data = pasteboard.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write(to pasteboard: NSPasteboard) throws {
        let item = NSPasteboardItem()
        guard item.setData(try JSONEncoder().encode(self), forType: Self.type) else {
            throw StudioError.message("クリップをコピーできませんでした。")
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw StudioError.message("クリップをコピーできませんでした。")
        }
    }
}
