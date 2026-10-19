import Foundation

enum Mode { case convert, tool, action }
enum Kind { case image, pdf, doc, data, video, audio, other }

struct Entry { let id: String; let label: String }

enum Catalog {
    static let labels: [String: String] = [
        "png": "PNG", "jpg": "JPEG", "heic": "HEIC", "tiff": "TIFF", "gif": "GIF", "bmp": "BMP",
        "pdf": "PDF", "txt": "Text", "docx": "Word", "rtf": "RTF", "html": "HTML",
        "csv": "CSV", "json": "JSON", "tsv": "TSV",
        "mp4": "MP4", "mov": "MOV", "m4a": "M4A", "wav": "WAV", "aiff": "AIFF",
        "rotate": "Rotate", "flip": "Flip", "half": "Half size", "gray": "Grayscale",
        "compress": "Compress", "onepdf": "One PDF", "merge": "Merge", "split": "Split pages",
        "snapshot": "Snapshot",
        "sha": "SHA-256", "copypath": "Copy path", "reveal": "Show in Finder", "duplicate": "Duplicate",
    ]
    static let actionIDs = ["sha", "copypath", "reveal", "duplicate"]

    static func label(_ id: String) -> String { labels[id] ?? id.uppercased() }

    static let symbols: [String: String] = [
        "png": "photo", "jpg": "photo", "heic": "photo", "tiff": "photo", "gif": "photo.stack", "bmp": "photo",
        "pdf": "doc.richtext", "txt": "doc.plaintext", "docx": "doc.text", "rtf": "textformat",
        "html": "chevron.left.forwardslash.chevron.right",
        "csv": "tablecells", "tsv": "tablecells", "json": "curlybraces",
        "mp4": "film", "mov": "film", "m4a": "waveform", "wav": "waveform", "aiff": "waveform",
        "rotate": "rotate.right", "flip": "arrow.left.and.right.righttriangle.left.righttriangle.right",
        "half": "minus.magnifyingglass", "gray": "circle.lefthalf.filled", "compress": "archivebox",
        "onepdf": "doc.on.doc", "merge": "arrow.triangle.merge", "split": "square.split.2x1",
        "snapshot": "camera",
        "sha": "number", "copypath": "link", "reveal": "folder", "duplicate": "plus.square.on.square",
    ]
    static func symbol(_ id: String) -> String { symbols[id] ?? "circle" }

    static func normExt(_ url: URL) -> String {
        let e = url.pathExtension.lowercased()
        switch e {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "htm": return "html"
        case "aif": return "aiff"
        default: return e
        }
    }

    static func kind(_ url: URL) -> Kind {
        switch normExt(url) {
        case "png", "jpg", "heic", "tiff", "gif", "bmp", "webp", "avif": return .image
        case "pdf": return .pdf
        case "docx", "doc", "rtf", "rtfd", "odt", "txt", "text", "md", "markdown", "html", "webarchive": return .doc
        case "csv", "tsv", "json": return .data
        case "mov", "mp4", "m4v": return .video
        case "mp3", "wav", "aiff", "m4a", "caf", "aac", "flac": return .audio
        default: return .other
        }
    }

    static func convertTargets(_ url: URL) -> [String] {
        let e = normExt(url)
        let all: [String]
        switch kind(url) {
        case .image: all = ["png", "jpg", "heic", "tiff", "gif", "bmp", "pdf"]
        case .pdf: all = ["png", "jpg", "txt", "docx"]
        case .doc: all = ["pdf", "docx", "rtf", "html", "txt"]
        case .data: all = ["csv", "json", "tsv", "html"]
        case .video: all = ["mp4", "mov", "m4a"]
        case .audio: all = ["m4a", "wav", "aiff"]
        case .other: all = []
        }
        return all.filter { $0 != e }
    }

    static func toolTargets(_ urls: [URL]) -> [String] {
        let kinds = urls.map(kind)
        guard !kinds.isEmpty else { return [] }
        if kinds.allSatisfy({ $0 == .image }) {
            return ["rotate", "flip", "half", "gray", "compress"] + (urls.count > 1 ? ["onepdf"] : [])
        }
        if kinds.allSatisfy({ $0 == .pdf }) { return urls.count > 1 ? ["merge", "split"] : ["split"] }
        if kinds.allSatisfy({ $0 == .video }) { return ["snapshot"] }
        return []
    }

    /// Returns the mode actually used (tools fall back to file actions) and its slices.
    static func entries(mode: Mode, urls: [URL]) -> (Mode, [Entry]) {
        let actions = actionIDs.map { Entry(id: $0, label: label($0)) }
        switch mode {
        case .action:
            return (.action, actions)
        case .tool:
            let t = toolTargets(urls)
            if t.isEmpty { return (.action, actions) }
            let list = t.map { Entry(id: $0, label: label($0)) }
            return (.tool, t.count >= 2 ? list : list + actions)
        case .convert:
            if urls.isEmpty {
                return (.convert, ["pdf", "png", "jpg", "docx", "txt", "csv", "mp4", "m4a"].map { Entry(id: $0, label: label($0)) })
            }
            let sets = urls.map(convertTargets)
            var pick = sets[0].filter { t in sets.allSatisfy { $0.contains(t) } }
            if pick.count < 2 {
                var seen = Set<String>()
                pick = sets.flatMap { $0 }.filter { seen.insert($0).inserted }
            }
            if pick.isEmpty { return (.action, actions) }
            return (.convert, Array(pick.prefix(8)).map { Entry(id: $0, label: label($0)) })
        }
    }
}
