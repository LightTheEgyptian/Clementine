import AppKit
import PDFKit
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ClemError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Runner

enum Runner {
    static func run(mode: Mode, id: String, urls: [URL]) {
        if mode == .action || Catalog.actionIDs.contains(id) { runAction(id, urls); return }
        let label = mode == .convert ? "Converting to \(Catalog.label(id))" : "\(Catalog.label(id))…"
        let n = urls.count
        HUD.shared.progress(n == 1 ? "\(label) · \(urls[0].lastPathComponent)" : "\(label) · \(n) files", 0.05)

        DispatchQueue.global(qos: .userInitiated).async {
            var outs: [URL] = []
            var errors: [String] = []
            let report: (Int, Double) -> Void = { i, part in
                let v = (Double(i) + part) / Double(max(n, 1))
                DispatchQueue.main.async {
                    HUD.shared.progress(n == 1 ? "\(label) · \(urls[0].lastPathComponent)" : "\(label) · \(i + 1) of \(n)", v)
                }
            }
            if id == "onepdf" || id == "merge" {
                do { outs.append(try combine(id, urls)) } catch { errors.append(error.localizedDescription) }
            } else {
                for (i, u) in urls.enumerated() {
                    report(i, 0.1)
                    do { outs += try single(mode, id, u) { report(i, $0) } }
                    catch { errors.append(n == 1 ? error.localizedDescription : "\(u.lastPathComponent): \(error.localizedDescription)") }
                }
            }
            DispatchQueue.main.async {
                if outs.isEmpty {
                    HUD.shared.finish("Couldn't finish · " + (errors.first ?? "Nothing was made."), outputs: [], error: true)
                    NSSound.beep()
                } else if errors.isEmpty {
                    HUD.shared.finish(outs.count == 1 ? "Done · \(outs[0].lastPathComponent)" : "Done · \(outs.count) files", outputs: outs)
                } else {
                    HUD.shared.finish("\(outs.count) done, \(errors.count) failed · \(errors[0])", outputs: outs, error: true)
                }
            }
        }
    }

    private static func onMain<T>(_ f: () throws -> T) throws -> T {
        if Thread.isMainThread { return try f() }
        return try DispatchQueue.main.sync(execute: f)
    }

    static func single(_ mode: Mode, _ id: String, _ u: URL, _ progress: @escaping (Double) -> Void) throws -> [URL] {
        let kind = Catalog.kind(u)
        if mode == .tool {
            switch id {
            case "rotate", "flip", "half", "gray", "compress":
                guard kind == .image else { throw ClemError("\(Catalog.label(id)) works on images.") }
                let img = try Img.apply(id, try Img.load(u))
                let ext = id == "compress" ? "jpg" : Img.keepExt(u)
                let suffix = ["rotate": "rotated", "flip": "flipped", "half": "half", "gray": "gray", "compress": "compressed"][id]!
                let dst = Out.file(u, suffix: suffix, ext: ext)
                try Img.write(img, to: dst, ext: ext, quality: id == "compress" ? 0.7 : 0.92)
                return [dst]
            case "split":
                let doc = try PDFx.open(u)
                let dir = try Out.folder(u, suffix: "pages")
                let pad = String(doc.pageCount).count
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                    let one = PDFDocument()
                    one.insert(page, at: 0)
                    let num = String(repeating: "0", count: max(0, pad - String(i + 1).count)) + String(i + 1)
                    one.write(to: dir.appendingPathComponent("\(u.deletingPathExtension().lastPathComponent) page \(num).pdf"))
                    progress(Double(i + 1) / Double(doc.pageCount))
                }
                return [dir]
            case "snapshot":
                let asset = AVURLAsset(url: u)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                let secs = CMTimeGetSeconds(asset.duration)
                let t = CMTime(seconds: secs.isFinite && secs > 2 ? 1 : 0, preferredTimescale: 600)
                let cg = try gen.copyCGImage(at: t, actualTime: nil)
                let dst = Out.file(u, suffix: "snapshot", ext: "png")
                try Img.write(cg, to: dst, ext: "png")
                return [dst]
            default:
                throw ClemError("Unknown tool.")
            }
        }

        let label = Catalog.label(id)
        guard Catalog.convertTargets(u).contains(id) else {
            throw ClemError("A .\(u.pathExtension.lowercased()) file can't become \(label).")
        }
        switch kind {
        case .image:
            let img = try Img.load(u)
            let dst = Out.file(u, ext: id)
            if id == "pdf" { try Img.pdf([img], to: dst) } else { try Img.write(img, to: dst, ext: id) }
            return [dst]

        case .pdf:
            let doc = try PDFx.open(u)
            if id == "txt" {
                let text = doc.string ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ClemError("No text found. This PDF is probably scanned images.")
                }
                let dst = Out.file(u, ext: "txt")
                try text.write(to: dst, atomically: true, encoding: .utf8)
                return [dst]
            }
            if id == "docx" {
                let all = NSMutableAttributedString()
                for i in 0..<doc.pageCount {
                    if let a = doc.page(at: i)?.attributedString { all.append(a); all.append(NSAttributedString(string: "\n\n")) }
                }
                let dst = Out.file(u, ext: "docx")
                try onMain { try Docs.write(all, to: dst, ext: "docx") }
                return [dst]
            }
            // pages to images
            let count = doc.pageCount
            let dir: URL = try (count > 1 ? Out.folder(u, suffix: "images") : u.deletingLastPathComponent())
            var outs: [URL] = []
            let pad = String(count).count
            for i in 0..<count {
                guard let page = doc.page(at: i), let img = PDFx.render(page) else { continue }
                let num = String(repeating: "0", count: max(0, pad - String(i + 1).count)) + String(i + 1)
                let base = u.deletingPathExtension().lastPathComponent + (count > 1 ? " page \(num)" : "")
                let dst = Out.unique(count > 1 ? dir : Out.dir(u), base, id)
                try Img.write(img, to: dst, ext: id)
                outs.append(dst)
                progress(Double(i + 1) / Double(count))
            }
            return count > 1 ? [dir] : outs

        case .doc:
            let dst = Out.file(u, ext: id)
            try onMain {
                let s = try Docs.read(u)
                try Docs.write(s, to: dst, ext: id)
            }
            return [dst]

        case .data:
            let rows = try Table.read(u)
            let dst = Out.file(u, ext: id)
            try Table.write(rows, to: dst, ext: id, title: u.deletingPathExtension().lastPathComponent)
            return [dst]

        case .video:
            let dst = Out.file(u, ext: id)
            try Media.exportVideo(u, to: dst, ext: id, progress: progress)
            return [dst]

        case .audio:
            let dst = Out.file(u, ext: id)
            try Media.convertAudio(u, to: dst, ext: id)
            return [dst]

        case .other:
            throw ClemError("This file type isn't supported.")
        }
    }

    static func combine(_ id: String, _ urls: [URL]) throws -> URL {
        let first = urls[0]
        if id == "onepdf" {
            let imgs = try urls.filter { Catalog.kind($0) == .image }.map { try Img.load($0) }
            guard !imgs.isEmpty else { throw ClemError("One PDF needs images.") }
            let dst = Out.unique(Out.dir(first), "Combined images", "pdf")
            try Img.pdf(imgs, to: dst)
            return dst
        }
        let pdfs = urls.filter { Catalog.kind($0) == .pdf }
        guard pdfs.count >= 2 else { throw ClemError("Merging needs two or more PDFs.") }
        let out = PDFDocument()
        for u in pdfs {
            let d = try PDFx.open(u)
            for i in 0..<d.pageCount {
                if let p = d.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
            }
        }
        let dst = Out.unique(Out.dir(first), "Merged", "pdf")
        guard out.write(to: dst) else { throw ClemError("Couldn't save the merged PDF.") }
        return dst
    }

    static func runAction(_ id: String, _ urls: [URL]) {
        switch id {
        case "copypath":
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            HUD.shared.finish(urls.count == 1 ? "Path copied" : "\(urls.count) paths copied", outputs: [])
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case "duplicate":
            var outs: [URL] = []
            for u in urls {
                let dst = Out.file(u, suffix: "copy", ext: u.pathExtension)
                if (try? FileManager.default.copyItem(at: u, to: dst)) != nil { outs.append(dst) }
            }
            HUD.shared.finish(outs.isEmpty ? "Couldn't duplicate" : "Duplicated \(outs.count) file\(outs.count == 1 ? "" : "s")", outputs: outs)
        case "sha":
            HUD.shared.progress("Hashing \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")", 0.3)
            DispatchQueue.global(qos: .userInitiated).async {
                let lines = urls.map { u -> String in
                    let h = (try? Hash.sha256(u)) ?? "error"
                    return urls.count == 1 ? h : "\(h)  \(u.lastPathComponent)"
                }
                DispatchQueue.main.async {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(lines.joined(separator: "\n"), forType: .string)
                    let short = urls.count == 1 ? String(lines[0].prefix(16)) + "…" : "\(urls.count) checksums"
                    HUD.shared.finish("SHA-256 copied · \(short)", outputs: [])
                }
            }
        default:
            break
        }
    }
}

// MARK: - Output naming

enum Out {
    static func dir(_ src: URL) -> URL {
        let d = src.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: d.path) { return d }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
    static func unique(_ dir: URL, _ base: String, _ ext: String) -> URL {
        let name = ext.isEmpty ? base : "\(base).\(ext)"
        var url = dir.appendingPathComponent(name)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        return url
    }
    static func file(_ src: URL, suffix: String? = nil, ext: String) -> URL {
        var base = src.deletingPathExtension().lastPathComponent
        if let s = suffix { base += " \(s)" }
        return unique(dir(src), base, ext)
    }
    static func folder(_ src: URL, suffix: String) throws -> URL {
        let d = unique(dir(src), src.deletingPathExtension().lastPathComponent + " \(suffix)", "")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

// MARK: - Images

enum Img {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func type(_ ext: String) -> UTType {
        switch ext {
        case "jpg": return .jpeg
        case "heic": return .heic
        case "tiff": return .tiff
        case "gif": return .gif
        case "bmp": return .bmp
        default: return .png
        }
    }
    static func keepExt(_ u: URL) -> String {
        let e = Catalog.normExt(u)
        return ["png", "jpg", "heic", "tiff"].contains(e) ? e : "png"
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ClemError("Couldn't open this image.") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 4096
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 4096
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ClemError("Couldn't read this image.")
        }
        return img
    }

    static func context(_ w: Int, _ h: Int, gray: Bool = false) throws -> CGContext {
        let c: CGContext? = gray
            ? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            : CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = c else { throw ClemError("This image is too large.") }
        ctx.interpolationQuality = .high
        return ctx
    }

    static func make(_ ctx: CGContext) throws -> CGImage {
        guard let i = ctx.makeImage() else { throw ClemError("Couldn't build the image.") }
        return i
    }

    static func flatten(_ img: CGImage) throws -> CGImage {
        let c = try context(img.width, img.height)
        c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return try make(c)
    }

    static func apply(_ tool: String, _ img: CGImage) throws -> CGImage {
        let w = img.width, h = img.height
        switch tool {
        case "rotate":
            let c = try context(h, w)
            c.translateBy(x: 0, y: CGFloat(w))
            c.rotate(by: -.pi / 2)
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return try make(c)
        case "flip":
            let c = try context(w, h)
            c.translateBy(x: CGFloat(w), y: 0)
            c.scaleBy(x: -1, y: 1)
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return try make(c)
        case "half":
            let nw = max(1, w / 2), nh = max(1, h / 2)
            let c = try context(nw, nh)
            c.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
            return try make(c)
        case "gray":
            let c = try context(w, h, gray: true)
            c.setFillColor(gray: 1, alpha: 1)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return try make(c)
        default:
            return img
        }
    }

    static func write(_ img: CGImage, to url: URL, ext: String, quality: Double = 0.92) throws {
        let t = type(ext)
        let image = (t == .jpeg || t == .bmp) ? try flatten(img) : img
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, t.identifier as CFString, 1, nil) else {
            throw ClemError("This Mac can't write \(ext.uppercased()) images.")
        }
        CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw ClemError("Couldn't save the image.") }
    }

    static func pdf(_ images: [CGImage], to url: URL) throws {
        let doc = PDFDocument()
        for (i, img) in images.enumerated() {
            let flat = try flatten(img)
            let ns = NSImage(cgImage: flat, size: NSSize(width: img.width, height: img.height))
            guard let page = PDFPage(image: ns) else { throw ClemError("Couldn't add an image to the PDF.") }
            doc.insert(page, at: i)
        }
        guard doc.write(to: url) else { throw ClemError("Couldn't save the PDF.") }
    }
}

// MARK: - PDF

enum PDFx {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let d = PDFDocument(url: url) else { throw ClemError("This PDF couldn't be opened.") }
        if d.isLocked { throw ClemError("This PDF is password-protected.") }
        return d
    }
    static func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let b = page.bounds(for: .mediaBox)
        var size = CGSize(width: b.width * scale, height: b.height * scale)
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let ns = page.thumbnail(of: size, for: .mediaBox)
        var r = CGRect(origin: .zero, size: ns.size)
        return ns.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
}

// MARK: - Documents (Word, RTF, HTML, text, Markdown)

enum Docs {
    static func read(_ url: URL) throws -> NSAttributedString {
        let ext = Catalog.normExt(url)
        let base: NSAttributedString
        if ext == "txt" || ext == "text" || ext == "md" || ext == "markdown" {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            if ext == "md" || ext == "markdown",
               let md = try? NSAttributedString(markdown: text,
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
                                                baseURL: nil) {
                base = md
            } else {
                base = NSAttributedString(string: text)
            }
        } else {
            base = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
        let m = NSMutableAttributedString(attributedString: base)
        let all = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.font, in: all) { v, r, _ in
            if v == nil { m.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: r) }
        }
        return m
    }

    static func write(_ s: NSAttributedString, to url: URL, ext: String) throws {
        let range = NSRange(location: 0, length: s.length)
        switch ext {
        case "txt":
            try s.string.write(to: url, atomically: true, encoding: .utf8)
        case "pdf":
            try pdf(s, to: url)
        default:
            let type: NSAttributedString.DocumentType = ext == "docx" ? .officeOpenXML : ext == "rtf" ? .rtf : .html
            var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .html { attrs[.characterEncoding] = NSNumber(value: String.Encoding.utf8.rawValue) }
            let data = try s.data(from: range, documentAttributes: attrs)
            try data.write(to: url)
        }
    }

    /// Lays text out on A4 pages and draws it into a real (selectable-text) PDF.
    static func pdf(_ s: NSAttributedString, to url: URL) throws {
        let page = CGSize(width: 595.28, height: 841.89), margin: CGFloat = 56
        let storage = NSTextStorage(attributedString: s)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let textSize = CGSize(width: page.width - margin * 2, height: page.height - margin * 2)
        var containers: [NSTextContainer] = []
        repeat {
            let tc = NSTextContainer(size: textSize)
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            containers.append(tc)
            let g = lm.glyphRange(for: tc)
            if g.length == 0 && containers.count > 1 { break }
        } while NSMaxRange(lm.glyphRange(for: containers.last!)) < lm.numberOfGlyphs && containers.count < 3000

        var box = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ClemError("Couldn't create the PDF.") }
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for tc in containers {
                let range = lm.glyphRange(for: tc)
                if range.length == 0 && containers.count > 1 { continue }
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: page.height)
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                lm.drawBackground(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
                lm.drawGlyphs(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
                NSGraphicsContext.restoreGraphicsState()
                ctx.restoreGState()
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
    }
}

// MARK: - Tables (CSV, TSV, JSON)

enum Table {
    static func read(_ url: URL) throws -> [[String]] {
        let data = try Data(contentsOf: url)
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        switch Catalog.normExt(url) {
        case "json": return try fromJSON(data)
        case "tsv": return parse(text, sep: "\t")
        default: return parse(text, sep: ",")
        }
    }

    static func parse(_ text: String, sep: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func fromJSON(_ data: Data) throws -> [[String]] {
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) } catch { throw ClemError("This JSON file has a syntax error.") }
        var list: [Any]
        if let a = obj as? [Any] { list = a }
        else if let d = obj as? [String: Any] {
            if let k = d.keys.sorted().first(where: { d[$0] is [Any] }) { list = d[k] as! [Any] } else { list = [d] }
        } else { list = [obj] }
        var headers: [String] = []
        var seen = Set<String>()
        var flat: [[String: String]] = []
        for item in list {
            var row: [String: String] = [:]
            if let d = item as? [String: Any] { flatten(d, "", &row) } else { row["value"] = str(item) }
            for k in row.keys.sorted() where seen.insert(k).inserted { headers.append(k) }
            flat.append(row)
        }
        return [headers] + flat.map { r in headers.map { r[$0] ?? "" } }
    }

    private static func flatten(_ d: [String: Any], _ prefix: String, _ out: inout [String: String]) {
        for (k, v) in d {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let sub = v as? [String: Any] { flatten(sub, key, &out) } else { out[key] = str(v) }
        }
    }

    private static func str(_ v: Any) -> String {
        if v is NSNull { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v),
           let s = String(data: d, encoding: .utf8) { return s }
        return "\(v)"
    }

    private static func jsonString(_ s: String) -> String {
        var o = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if ch.value < 0x20 { o += String(format: "\\u%04x", ch.value) } else { o.unicodeScalars.append(ch) }
            }
        }
        return o + "\""
    }

    private static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func write(_ rows: [[String]], to url: URL, ext: String, title: String) throws {
        let width = rows.map(\.count).max() ?? 0
        let grid = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        var out = ""
        switch ext {
        case "csv", "tsv":
            let sep = ext == "csv" ? "," : "\t"
            if ext == "csv" { out = "\u{FEFF}" }
            out += grid.map { r in
                r.map { f in
                    (f.contains(sep) || f.contains("\"") || f.contains("\n") || f.contains("\r"))
                        ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
                }.joined(separator: sep)
            }.joined(separator: "\n") + "\n"
        case "json":
            guard let head = grid.first else { out = "[]\n"; break }
            let body = grid.dropFirst().map { r in
                "  {" + head.enumerated().map { i, h in "\(jsonString(h)): \(jsonString(r[i]))" }.joined(separator: ", ") + "}"
            }
            out = "[\n" + body.joined(separator: ",\n") + "\n]\n"
        default:
            let head = grid.first ?? []
            out = "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>\(html(title))</title>\n<style>body{font-family:-apple-system,system-ui,sans-serif;margin:2rem}table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:4px 8px;text-align:start}th{background:#f2f2ec}</style></head><body>\n<table>\n<thead><tr>"
            out += head.map { "<th dir=\"auto\">\(html($0))</th>" }.joined()
            out += "</tr></thead>\n<tbody>\n"
            out += grid.dropFirst().map { r in "<tr>" + r.map { "<td dir=\"auto\">\(html($0))</td>" }.joined() + "</tr>" }.joined(separator: "\n")
            out += "\n</tbody>\n</table>\n</body></html>\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Audio and video

enum Media {
    static func exportVideo(_ src: URL, to dst: URL, ext: String, progress: @escaping (Double) -> Void) throws {
        let asset = AVURLAsset(url: src)
        let type: AVFileType = ext == "mp4" ? .mp4 : ext == "mov" ? .mov : .m4a
        let presets = ext == "m4a" ? [AVAssetExportPresetAppleM4A]
                                   : [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        var lastError: Error?
        for preset in presets {
            guard let s = AVAssetExportSession(asset: asset, presetName: preset),
                  s.supportedFileTypes.contains(type) else { continue }
            try? FileManager.default.removeItem(at: dst)
            s.outputURL = dst
            s.outputFileType = type
            let done = DispatchSemaphore(value: 0)
            s.exportAsynchronously { done.signal() }
            while done.wait(timeout: .now() + 0.25) == .timedOut { progress(Double(s.progress)) }
            if s.status == .completed { return }
            lastError = s.error
        }
        try? FileManager.default.removeItem(at: dst)
        throw ClemError(lastError?.localizedDescription ?? "This video can't be exported as \(ext.uppercased()).")
    }

    static func convertAudio(_ src: URL, to dst: URL, ext: String) throws {
        let input = try AVAudioFile(forReading: src)
        let fmt = input.processingFormat
        var settings: [String: Any] = [AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: fmt.channelCount]
        switch ext {
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 192_000
        default:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = ext == "aiff"
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        let output = try AVAudioFile(forWriting: dst, settings: settings,
                                     commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65536) else { throw ClemError("Couldn't read the audio.") }
        while input.framePosition < input.length {
            try input.read(into: buf)
            if buf.frameLength == 0 { break }
            try output.write(from: buf)
        }
    }
}

// MARK: - Checksums

enum Hash {
    static func sha256(_ url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = SHA256()
        while let d = try fh.read(upToCount: 1 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
