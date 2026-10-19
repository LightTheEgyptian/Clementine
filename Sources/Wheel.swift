import AppKit
import QuartzCore

final class WheelController {
    static let shared = WheelController()
    static let size: CGFloat = 320

    private let panel: NSPanel
    private let view: WheelView
    private var requested: Mode?
    private var urls: [URL] = []
    private(set) var isOpen = false
    private var generation = 0

    private init() {
        view = WheelView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the wheel draws its own soft shadow
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = view
        view.onDrop = { [weak self] mode, entry, urls in self?.dropped(mode: mode, entry: entry, urls: urls) }
        view.onURLs = { [weak self] urls in self?.learned(urls) }
    }

    static func mode(from flags: NSEvent.ModifierFlags) -> Mode? {
        if flags.contains(.shift) { return .convert }
        if flags.contains(.command) || flags.contains(.option) { return .tool }
        if flags.contains(.control) { return .action }
        return nil
    }

    func update(mods: NSEvent.ModifierFlags, at point: NSPoint, urls: [URL]) {
        if !urls.isEmpty && self.urls.isEmpty { self.urls = urls }
        guard let m = Self.mode(from: mods) else { return }
        if isOpen && m == requested { return }
        requested = m
        refresh()
        if !isOpen { open(at: point) }
    }

    private func learned(_ urls: [URL]) {
        guard self.urls.isEmpty, !urls.isEmpty else { return }
        self.urls = urls
        refresh()
    }

    private func refresh() {
        guard let m = requested else { return }
        let (mode, entries) = Catalog.entries(mode: m, urls: urls)
        let subject: String
        if urls.isEmpty { subject = "Files" }
        else if urls.count == 1 { subject = urls[0].pathExtension.uppercased().isEmpty ? "File" : urls[0].pathExtension.uppercased() }
        else { subject = "\(urls.count) files" }
        view.configure(mode: mode, entries: entries, subject: subject)
    }

    private func open(at p: NSPoint) {
        generation += 1
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: p.x - Self.size / 2, y: p.y - Self.size / 2)
        if let f = screen?.frame {
            origin.x = min(max(origin.x, f.minX), f.maxX - Self.size)
            origin.y = min(max(origin.y, f.minY), f.maxY - Self.size)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        isOpen = true
        view.appear()
    }

    func dragEnded() {
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.generation == g, self.isOpen else { return }
            self.close()
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        requested = nil
        urls = []
        generation += 1
        let g = generation
        view.disappear()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.generation == g else { return }
            self.panel.orderOut(nil)
        }
    }

    private func dropped(mode: Mode, entry: Entry, urls: [URL]) {
        let files = urls.isEmpty ? self.urls : urls
        close()
        guard !files.isEmpty else { return }
        Runner.run(mode: mode, id: entry.id, urls: files)
    }
}

/// The radial menu: a frosted ring of slices with a highlight that glides
/// between them, plus a hub that names what will happen.
final class WheelView: NSView {
    var onDrop: ((Mode, Entry, [URL]) -> Void)?
    var onURLs: (([URL]) -> Void)?

    private(set) var mode: Mode = .convert
    private(set) var entries: [Entry] = []
    private var subject = ""
    private(set) var hover = -1
    private var inHub = false

    // geometry
    private let r1: CGFloat = 132      // outer edge of the ring
    private let r0: CGFloat = 60       // inner edge of the ring
    private let rHub: CGFloat = 51     // the centre disc
    private let gap: CGFloat = 3       // even gap between slices

    // layers and views
    private let shadowLayer = CALayer()
    private let material = NSVisualEffectView()
    private let tintHost = NSView()
    private let tintMask = CALayer()
    private let highlight = CAShapeLayer()
    private let rim = CAShapeLayer()
    private var sliceViews: [(icon: NSImageView, label: NSTextField)] = []
    private let caption = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private var angle: CGFloat = 0     // current highlight rotation, kept continuous
    private var highlightShown = false

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        registerForDraggedTypes([.fileURL])

        shadowLayer.frame = bounds
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.28
        shadowLayer.shadowRadius = 22
        shadowLayer.shadowOffset = CGSize(width: 0, height: -8)
        let sp = CGMutablePath()
        sp.addEllipse(in: CGRect(x: center.x - r1, y: center.y - r1, width: r1 * 2, height: r1 * 2))
        shadowLayer.shadowPath = sp
        layer?.addSublayer(shadowLayer)

        material.frame = bounds
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        addSubview(material)

        tintHost.frame = bounds
        tintHost.wantsLayer = true
        addSubview(tintHost)
        tintMask.frame = bounds
        tintMask.contentsGravity = .resize
        tintHost.layer?.mask = tintMask

        highlight.frame = bounds
        highlight.opacity = 0
        tintHost.layer?.addSublayer(highlight)

        rim.frame = bounds
        rim.fillColor = nil
        rim.strokeColor = NSColor(white: 1, alpha: 0.22).cgColor
        rim.lineWidth = 1
        let rp = CGMutablePath()
        rp.addEllipse(in: CGRect(x: center.x - r1 + 0.5, y: center.y - r1 + 0.5, width: r1 * 2 - 1, height: r1 * 2 - 1))
        rp.addEllipse(in: CGRect(x: center.x - rHub + 0.5, y: center.y - rHub + 0.5, width: rHub * 2 - 1, height: rHub * 2 - 1))
        rim.path = rp
        tintHost.layer?.addSublayer(rim)

        for f in [caption, title] {
            f.alignment = .center
            f.lineBreakMode = .byTruncatingTail
            f.maximumNumberOfLines = 1
            addSubview(f)
        }
        caption.frame = NSRect(x: center.x - 44, y: center.y + 3, width: 88, height: 14)
        title.frame = NSRect(x: center.x - 44, y: center.y - 17, width: 88, height: 19)

        layer?.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: content

    private var accent: NSColor {
        switch mode {
        case .convert: return .systemOrange
        case .tool: return .systemGreen
        case .action: return .controlAccentColor
        }
    }

    private var modeName: String {
        switch mode {
        case .convert: return "CONVERT"
        case .tool: return "TOOLS"
        case .action: return "ACTIONS"
        }
    }

    func configure(mode: Mode, entries: [Entry], subject: String) {
        let changed = entries.map(\.id) != self.entries.map(\.id) || mode != self.mode
        self.mode = mode
        self.subject = subject
        if changed {
            self.entries = entries
            hover = -1
            rebuild()
        }
        updateHub()
    }

    private func rebuild() {
        let n = max(entries.count, 1)
        let step = 2 * CGFloat.pi / CGFloat(n)

        if let mask = makeMask(count: entries.count) {
            material.maskImage = NSImage(cgImage: mask, size: bounds.size)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            tintMask.contents = mask
            CATransaction.commit()
        }

        let wedge = CGMutablePath()
        if entries.count <= 1 {
            wedge.addEllipse(in: CGRect(x: center.x - r1, y: center.y - r1, width: r1 * 2, height: r1 * 2))
            wedge.addEllipse(in: CGRect(x: center.x - r0, y: center.y - r0, width: r0 * 2, height: r0 * 2))
            highlight.fillRule = .evenOdd
        } else {
            wedge.addArc(center: center, radius: r1, startAngle: .pi / 2 + step / 2, endAngle: .pi / 2 - step / 2, clockwise: true)
            wedge.addArc(center: center, radius: r0, startAngle: .pi / 2 - step / 2, endAngle: .pi / 2 + step / 2, clockwise: false)
            wedge.closeSubpath()
            highlight.fillRule = .nonZero
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.path = wedge
        highlight.fillColor = accent.cgColor
        highlight.opacity = 0
        CATransaction.commit()
        highlightShown = false

        sliceViews.forEach { $0.icon.removeFromSuperview(); $0.label.removeFromSuperview() }
        sliceViews = []
        let mid = (r0 + r1) / 2
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        for (i, e) in entries.enumerated() {
            let a = .pi / 2 - CGFloat(i) * step
            let p = entries.count == 1 ? CGPoint(x: center.x, y: center.y + mid) : CGPoint(x: center.x + cos(a) * mid, y: center.y + sin(a) * mid)

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: Catalog.symbol(e.id), accessibilityDescription: e.label)?
                .withSymbolConfiguration(iconConfig)
            icon.frame = NSRect(x: p.x - 12, y: p.y + 1, width: 24, height: 20)
            icon.imageScaling = .scaleProportionallyDown

            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: p.x - 38, y: p.y - 15, width: 76, height: 14)
            label.attributedStringValue = styled(e.label, size: 10.5, weight: .semibold, kern: 0.15, color: .labelColor)

            addSubview(icon, positioned: .below, relativeTo: caption)
            addSubview(label, positioned: .below, relativeTo: caption)
            sliceViews.append((icon, label))
        }
        paintSlices()
    }

    private func styled(_ s: String, size: CGFloat, weight: NSFont.Weight, kern: CGFloat, color: NSColor) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .kern: kern,
            .foregroundColor: color,
            .paragraphStyle: para,
        ])
    }

    private func paintSlices() {
        for (i, v) in sliceViews.enumerated() {
            let on = i == hover
            let fg: NSColor = on ? .white : .labelColor
            v.icon.contentTintColor = on ? .white : .secondaryLabelColor
            v.label.attributedStringValue = styled(entries[i].label, size: 10.5, weight: .semibold, kern: 0.15, color: fg)
        }
    }

    private func updateHub() {
        caption.attributedStringValue = styled(modeName, size: 9, weight: .semibold, kern: 0.8, color: .secondaryLabelColor)
        let text: String
        var color: NSColor = .labelColor
        if hover >= 0 { text = entries[hover].label }
        else if inHub { text = "Cancel"; color = .secondaryLabelColor }
        else { text = subject }
        title.attributedStringValue = styled(text, size: 14, weight: .semibold, kern: -0.15, color: color)
    }

    /// Alpha mask: the ring with even gaps between slices, plus the hub disc.
    private func makeMask(count n: Int) -> CGImage? {
        let scale: CGFloat = 2
        let px = Int(bounds.width * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let c = center
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: c.x - r1, y: c.y - r1, width: r1 * 2, height: r1 * 2))
        ring.addEllipse(in: CGRect(x: c.x - r0, y: c.y - r0, width: r0 * 2, height: r0 * 2))
        ctx.addPath(ring)
        ctx.fillPath(using: .evenOdd)
        ctx.fillEllipse(in: CGRect(x: c.x - rHub, y: c.y - rHub, width: rHub * 2, height: rHub * 2))
        if n > 1 {
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(gap)
            let step = 2 * CGFloat.pi / CGFloat(n)
            for i in 0..<n {
                let a = .pi / 2 + step / 2 - CGFloat(i) * step
                ctx.move(to: CGPoint(x: c.x + cos(a) * (r0 - 2), y: c.y + sin(a) * (r0 - 2)))
                ctx.addLine(to: CGPoint(x: c.x + cos(a) * (r1 + 2), y: c.y + sin(a) * (r1 + 2)))
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }

    // MARK: appear / disappear (scales out from the pointer and back into it)

    func appear() {
        guard let l = layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if (l.presentation()?.opacity ?? 0) < 0.05 {
            l.sublayerTransform = Motion.scale(0.88, about: center)
        }
        CATransaction.commit()
        Motion.set(l, "opacity", to: Float(1), response: 0.22)
        Motion.set(l, "sublayerTransform", to: NSValue(caTransform3D: Motion.scale(1, about: center)), response: 0.3)
    }

    func disappear() {
        guard let l = layer else { return }
        Motion.set(l, "opacity", to: Float(0), response: 0.16)
        Motion.set(l, "sublayerTransform", to: NSValue(caTransform3D: Motion.scale(0.9, about: center)), response: 0.18)
        setHover(-1, inHub: false)
    }

    // MARK: hover

    private func index(at p: CGPoint) -> (Int, Bool) {
        let n = entries.count
        let d = hypot(p.x - center.x, p.y - center.y)
        if d <= rHub { return (-1, true) }
        guard n > 0, d >= r0 - 6, d <= r1 + 48 else { return (-1, false) }
        if n == 1 { return (0, false) }
        var off = CGFloat.pi / 2 - atan2(p.y - center.y, p.x - center.x)
        while off < 0 { off += 2 * .pi }
        while off >= 2 * .pi { off -= 2 * .pi }
        let step = 2 * CGFloat.pi / CGFloat(n)
        return (Int((off + step / 2) / step) % n, false)
    }

    private func setHover(_ i: Int, inHub hub: Bool) {
        let hubChanged = hub != inHub
        inHub = hub
        guard i != hover || hubChanged else { return }
        let old = hover
        hover = i
        if i != old {
            moveHighlight(to: i)
            paintSlices()
            if i >= 0 { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        updateHub()
    }

    private func moveHighlight(to i: Int) {
        guard i >= 0, !entries.isEmpty else {
            Motion.set(highlight, "opacity", to: Float(0), response: 0.18)
            highlightShown = false
            return
        }
        let step = 2 * CGFloat.pi / CGFloat(entries.count)
        let target = -CGFloat(i) * step
        if !highlightShown {
            // appear in place: no sweep from wherever it last was
            angle = target
            Motion.set(highlight, "transform.rotation.z", to: angle, animated: false)
            Motion.set(highlight, "opacity", to: Float(1), response: 0.16)
            highlightShown = true
            return
        }
        var delta = target - angle
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        angle += delta
        Motion.set(highlight, "transform.rotation.z", to: angle, response: 0.24)
    }

    // MARK: drag destination

    private func urls(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func track(_ info: NSDraggingInfo) -> NSDragOperation {
        let p = convert(info.draggingLocation, from: nil)
        let (i, hub) = index(at: p)
        setHover(i, inHub: hub)
        return i >= 0 ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onURLs?(urls(from: sender))
        return track(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setHover(-1, inHub: false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hover >= 0 }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard hover >= 0, hover < entries.count else { return false }
        let entry = entries[hover]
        let files = urls(from: sender)
        let m = mode
        DispatchQueue.main.async { self.onDrop?(m, entry, files) }
        return true
    }
}
