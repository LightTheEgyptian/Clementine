import AppKit
import QuartzCore

/// A black pill that slides down out of the notch, shows progress, then slides
/// back up the same way it came.
final class HUD: NSObject {
    static let shared = HUD()

    private let panel: NSPanel
    private let root = NSView()
    private let pill = NSView()
    private let spinner = NSProgressIndicator()
    private let glyph = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let track = CALayer()
    private let fill = CALayer()
    private var outputs: [URL] = []
    private var hideWork: DispatchWorkItem?
    private var shown = false
    private var generation = 0

    private let width: CGFloat = 380
    private let height: CGFloat = 72
    private let shadowPad: CGFloat = 24

    private override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let W = width + shadowPad * 2, H = height + shadowPad
        root.frame = NSRect(x: 0, y: 0, width: W, height: H)
        root.wantsLayer = true
        root.layer?.opacity = 0
        panel.contentView = root

        pill.frame = NSRect(x: shadowPad, y: shadowPad, width: width, height: height)
        pill.wantsLayer = true
        if let l = pill.layer {
            l.backgroundColor = NSColor.black.cgColor
            l.cornerRadius = 22
            l.cornerCurve = .continuous
            l.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.35
            l.shadowRadius = 16
            l.shadowOffset = CGSize(width: 0, height: -6)
            l.masksToBounds = false
        }
        root.addSubview(pill)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.frame = NSRect(x: 20, y: 30, width: 18, height: 18)
        pill.addSubview(spinner)

        glyph.frame = NSRect(x: 19, y: 29, width: 20, height: 20)
        glyph.isHidden = true
        pill.addSubview(glyph)

        titleField.frame = NSRect(x: 50, y: 37, width: 190, height: 18)
        titleField.lineBreakMode = .byTruncatingTail
        pill.addSubview(titleField)

        detailField.frame = NSRect(x: 50, y: 21, width: 190, height: 15)
        detailField.lineBreakMode = .byTruncatingMiddle
        pill.addSubview(detailField)

        button.frame = NSRect(x: width - 130, y: 26, width: 112, height: 26)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        button.layer?.cornerRadius = 13
        button.layer?.cornerCurve = .continuous
        button.attributedTitle = NSAttributedString(string: "Show in Finder", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        button.target = self
        button.action = #selector(reveal)
        button.isHidden = true
        pill.addSubview(button)

        track.frame = CGRect(x: 20, y: 10, width: width - 40, height: 3)
        track.cornerRadius = 1.5
        track.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        pill.layer?.addSublayer(track)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.frame = track.frame
        fill.cornerRadius = 1.5
        fill.backgroundColor = NSColor.systemOrange.cgColor
        fill.transform = CATransform3DMakeScale(0.02, 1, 1)
        pill.layer?.addSublayer(fill)
    }

    private func set(_ field: NSTextField, _ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, kern: CGFloat) {
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
            .kern: kern,
        ])
    }

    private func setText(_ text: String) {
        let parts = text.components(separatedBy: " · ")
        set(titleField, parts.first ?? text, size: 13.5, weight: .semibold, alpha: 1, kern: -0.1)
        set(detailField, parts.dropFirst().joined(separator: " · "), size: 11, weight: .regular, alpha: 0.6, kern: 0)
        let wide = button.isHidden
        titleField.frame.size.width = wide ? width - 70 : 190
        detailField.frame.size.width = wide ? width - 70 : 190
        if parts.count == 1 { titleField.frame.origin.y = 29 } else { titleField.frame.origin.y = 37 }
    }

    private func show() {
        generation += 1
        hideWork?.cancel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.frame, let l = root.layer else { return }
        if !shown {
            let W = width + shadowPad * 2, H = height + shadowPad
            panel.setFrame(NSRect(x: f.midX - W / 2, y: f.maxY - H, width: W, height: H), display: true)
            panel.orderFrontRegardless()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if (l.presentation()?.opacity ?? 0) < 0.05 {
                l.sublayerTransform = CATransform3DMakeTranslation(0, height + shadowPad, 0)
            }
            CATransaction.commit()
            shown = true
        }
        Motion.set(l, "opacity", to: Float(1), response: 0.2)
        Motion.set(l, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DIdentity), response: 0.38)
    }

    private func setProgress(_ v: Double) {
        let s = CGFloat(max(0.02, min(1, v)))
        Motion.set(fill, "transform.scale.x", to: s, response: 0.35)
    }

    func progress(_ text: String, _ value: Double) {
        spinner.isHidden = false
        spinner.startAnimation(nil)
        glyph.isHidden = true
        button.isHidden = true
        track.isHidden = false
        fill.isHidden = false
        setText(text)
        setProgress(value)
        show()
    }

    func finish(_ text: String, outputs: [URL], error: Bool = false) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        let symbol = error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        glyph.contentTintColor = error ? .systemOrange : .systemGreen
        glyph.isHidden = false
        self.outputs = outputs
        button.isHidden = outputs.isEmpty
        setText(text)
        setProgress(1)
        track.isHidden = true
        fill.isHidden = true
        show()
        scheduleHide(after: error ? 6 : 8)
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hide() {
        if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) { scheduleHide(after: 1.5); return }
        guard let l = root.layer else { return }
        shown = false
        generation += 1
        let g = generation
        // leave the way it came: back up into the notch
        Motion.set(l, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DMakeTranslation(0, height + shadowPad, 0)), response: 0.3)
        Motion.set(l, "opacity", to: Float(0), response: 0.3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == g else { return }
            self.panel.orderOut(nil)
        }
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
        scheduleHide(after: 0.4)
    }
}
