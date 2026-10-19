import AppKit

/// Watches for a file drag happening anywhere on screen by polling the mouse
/// button and the system drag pasteboard. No special permissions needed.
final class DragWatcher {
    var onUpdate: ((NSEvent.ModifierFlags, NSPoint, [URL]) -> Void)?
    var onEnd: (() -> Void)?

    private var timer: Timer?
    private var wasDown = false
    private var idleCount = 0
    private var active = false
    private var urls: [URL] = []
    private let pasteboard = NSPasteboard(name: .drag)

    func start() {
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = (NSEvent.pressedMouseButtons & 1) == 1
        if !down {
            if wasDown && active { onEnd?() }
            active = false
            urls = []
            idleCount = pasteboard.changeCount
            wasDown = false
            return
        }
        wasDown = true
        if !active && pasteboard.changeCount != idleCount {
            if pasteboard.types?.contains(.fileURL) == true {
                active = true
                urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            } else {
                idleCount = pasteboard.changeCount // a non-file drag; ignore it
            }
        }
        if active {
            onUpdate?(NSEvent.modifierFlags, NSEvent.mouseLocation, urls)
        }
    }
}
