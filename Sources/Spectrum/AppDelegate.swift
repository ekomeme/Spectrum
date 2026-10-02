import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = AudioEngineController()
    private var mainWindowController: MainWindowController?
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Start", action: #selector(toggleEngine), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildStatusItem()
        let controller = MainWindowController(engine: engine)
        controller.onHide = { [weak self] in self?.hideMainWindow() }
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        engine.restoreSession { [weak controller] in controller?.refresh() }
    }

    /// Closing the main window keeps Spectrum alive in the menu bar; only "Salir" quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// Some plugins (MetricAB among them) crash inside their own static destructors when the process exits
    /// while their JUCE timer thread is alive. Hosts work around it by saving everything, stopping audio,
    /// giving editors a moment to settle and then ending the process without running those destructors.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        engine.saveSession()
        engine.shutdown()
        UserDefaults.standard.synchronize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            _exit(0)
        }
        return .terminateLater
    }

    // MARK: - Show / hide

    @objc func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideMainWindow() {
        mainWindowController?.window?.orderOut(nil)
        for slot in engine.slots { slot.windowController?.dispose() }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func toggleEngine() {
        engine.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Status bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Spectrum")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Spectrum"
        }
        statusMenu.delegate = self
        statusMenu.addItem(withTitle: "Show Spectrum", action: #selector(showMainWindow), keyEquivalent: "")
        statusMenu.addItem(.separator())
        stateItem.isEnabled = false
        statusMenu.addItem(stateItem)
        statusMenu.addItem(toggleItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit Spectrum", action: #selector(quit), keyEquivalent: "q")
        for menuItem in statusMenu.items { menuItem.target = self }
        item.menu = statusMenu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let error = engine.lastError {
            stateItem.title = "⚠️ \(error)"
        } else if engine.isRunning {
            stateItem.title = "● Running · \(engine.statusDetail)"
        } else {
            stateItem.title = "○ Stopped"
        }
        toggleItem.title = engine.isRunning ? "Stop" : "Start"
    }

    // MARK: - Main menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Spectrum", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Spectrum", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Spectrum", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
