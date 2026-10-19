import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = DragWatcher()
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Icon.menuBar()
        statusItem.button?.toolTip = "Clementine"
        buildMenu()

        watcher.onUpdate = { mods, point, urls in
            WheelController.shared.update(mods: mods, at: point, urls: urls)
        }
        watcher.onEnd = { WheelController.shared.dragEnded() }
        watcher.start()

        if !UserDefaults.standard.bool(forKey: "seenIntro") {
            UserDefaults.standard.set(true, forKey: "seenIntro")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showHelp() }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Clementine is ready", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(withTitle: "How to Use…", action: #selector(showHelp), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Convert Files…", action: #selector(convertFiles), keyEquivalent: "").target = self
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clementine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "How to use Clementine"
        a.informativeText = """
        Drag files anywhere (from Finder or your Desktop) and, while you're still dragging, hold a key:

        Shift — convert wheel (PNG, JPEG, PDF, Word, MP4…)
        Command or Option — tools wheel (rotate, resize, compress, merge or split PDFs…)
        Control — file actions (SHA-256, copy path, show in Finder, duplicate)

        Move onto a slice and let go. The new file appears next to the original. Let go in the middle to cancel.

        Clementine lives in the menu bar (the orange dot).
        """
        a.addButton(withTitle: "Got it")
        a.runModal()
    }

    @objc func convertFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.message = "Choose files, then pick what to do with them."
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let urls = p.urls
        let menu = NSMenu()
        for (mode, title) in [(Mode.convert, "Convert to"), (Mode.tool, "Tools"), (Mode.action, "File actions")] {
            let (m, entries) = Catalog.entries(mode: mode, urls: urls)
            if m != mode || entries.isEmpty { continue }
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for e in entries {
                let item = MenuAction(title: "   " + e.label, mode: m, id: e.id, urls: urls)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change the login setting"
            a.informativeText = "Move Clementine into your Applications folder first, then try again. (\(error.localizedDescription))"
            a.runModal()
        }
    }
}

final class MenuAction: NSMenuItem {
    let mode: Mode
    let actionID: String
    let urls: [URL]
    init(title: String, mode: Mode, id: String, urls: [URL]) {
        self.mode = mode; self.actionID = id; self.urls = urls
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { Runner.run(mode: mode, id: actionID, urls: urls) }
}

enum Icon {
    static func menuBar() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor(calibratedRed: 0.93, green: 0.48, blue: 0.12, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 1, width: 14, height: 14)).fill()
            NSColor(calibratedRed: 0.22, green: 0.55, blue: 0.30, alpha: 1).setFill()
            let leaf = NSBezierPath()
            leaf.move(to: NSPoint(x: 9.5, y: 14.5))
            leaf.curve(to: NSPoint(x: 16, y: 17), controlPoint1: NSPoint(x: 11, y: 17.5), controlPoint2: NSPoint(x: 14, y: 18))
            leaf.curve(to: NSPoint(x: 9.5, y: 14.5), controlPoint1: NSPoint(x: 14, y: 15), controlPoint2: NSPoint(x: 11.5, y: 14))
            leaf.fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}
