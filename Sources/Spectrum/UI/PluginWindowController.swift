import AppKit
import AVFoundation
import CoreAudioKit

/// Hosts a plugin's own editor view (or a generic parameter view as fallback) in its own window.
final class PluginWindowController: NSWindowController, NSWindowDelegate {
    private let slot: PluginSlot
    private var viewController: NSViewController?
    private var pluginView: NSView?
    private var frameObserver: NSObjectProtocol?
    private var disposing = false

    init(slot: PluginSlot) {
        self.slot = slot
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = slot.displayName
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let placeholder = NSTextField(labelWithString: "Cargando interfaz de \(slot.name)…")
        placeholder.alignment = .center
        placeholder.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        placeholder.autoresizingMask = [.width, .height]
        window.contentView = placeholder

        slot.unit.auAudioUnit.requestViewController { [weak self] controller in
            DispatchQueue.main.async {
                guard let self else { return }
                if let controller {
                    self.install(controller.view, controller: controller)
                } else {
                    let generic = AUGenericView(audioUnit: slot.unit.audioUnit)
                    generic.showsExpertParameters = true
                    if generic.frame.size.width < 100 {
                        generic.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
                    }
                    self.install(generic, controller: nil)
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func install(_ view: NSView, controller: NSViewController?) {
        viewController = controller
        pluginView = view

        var size = view.frame.size
        if let controller, controller.preferredContentSize != .zero {
            size = controller.preferredContentSize
        }
        if size.width < 50 || size.height < 50 {
            let fitting = view.fittingSize
            size = (fitting.width > 50 && fitting.height > 50) ? fitting : NSSize(width: 640, height: 420)
        }

        // The plugin manages its own frame; a plain container lets us follow its size changes
        // without AppKit fighting it through autoresizing.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = []
        container.addSubview(view)
        window?.contentView = container
        window?.setContentSize(size)
        window?.center()

        view.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                               object: view, queue: .main) { [weak self] _ in
            self?.followPluginSize()
        }
    }

    private func followPluginSize() {
        guard let window, let pluginView else { return }
        let size = pluginView.frame.size
        guard size.width > 10, size.height > 10 else { return }
        let current = window.contentView?.frame.size ?? .zero
        if abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 {
            window.setContentSize(size)
        }
        if pluginView.frame.origin != .zero {
            pluginView.setFrameOrigin(.zero)
        }
    }

    /// Closing the window only hides it: AUv2 plugins often refuse to create their editor view a second time,
    /// so the view (and the window's position) is kept alive for the next "Interfaz" click.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if disposing { return true }
        sender.orderOut(nil)
        return false
    }

    /// Really tear the window down (plugin removed or app quitting).
    func dispose() {
        disposing = true
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        window?.close()
        pluginView?.removeFromSuperview()
        pluginView = nil
        viewController = nil
    }
}
