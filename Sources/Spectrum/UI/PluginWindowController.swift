import AppKit
import AudioToolbox
import AudioUnit
import AVFoundation
import CoreAudioKit

/// Mirror of the AUCocoaUIBase Objective‑C protocol (AUCocoaUIView.h), which Swift does not import.
@objc private protocol SpectrumCocoaUIFactory {
    @objc(uiViewForAudioUnit:withSize:)
    func uiView(forAudioUnit audioUnit: AudioUnit, withSize preferredSize: NSSize) -> NSView?
}

/// Hosts a plugin's editor view in its own window. A fresh editor view is created every time the window
/// is opened (as DAWs do): reusing a hidden view leaves some analysers with frozen displays.
final class PluginWindowController: NSWindowController, NSWindowDelegate {
    private let slot: PluginSlot
    private var viewController: NSViewController?
    private var pluginView: NSView?
    private var frameObserver: NSObjectProtocol?
    private(set) var usedGenericView = false
    var onClose: (() -> Void)?

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

        // 1) AUv2 Cocoa view factory: can be called as many times as we like.
        if ProcessInfo.processInfo.environment["SPECTRUM_NO_COCOAUI"] == nil, let view = Self.makeCocoaView(for: slot.unit) {
            install(view, controller: nil)
            return
        }
        // 2) AUv3 / bridge view controller.
        slot.unit.auAudioUnit.requestViewController { [weak self] controller in
            DispatchQueue.main.async {
                guard let self else { return }
                if let controller {
                    self.install(controller.view, controller: controller)
                } else {
                    // 3) Generic parameter view as a last resort.
                    let generic = AUGenericView(audioUnit: slot.unit.audioUnit)
                    generic.showsExpertParameters = true
                    if generic.frame.size.width < 100 {
                        generic.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
                    }
                    self.usedGenericView = true
                    self.install(generic, controller: nil)
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Creates the plugin's own Cocoa editor through kAudioUnitProperty_CocoaUI (AUv2 plugins).
    private static func makeCocoaView(for unit: AVAudioUnit) -> NSView? {
        let au = unit.audioUnit
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioUnitGetPropertyInfo(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr,
              size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }
        let count = (Int(size) - MemoryLayout<CFURL>.size) / MemoryLayout<CFString>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { raw.deallocate() }
        guard AudioUnitGetProperty(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }
        let info = raw.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self)
        let bundleURL = Unmanaged<CFURL>.fromOpaque(UnsafeRawPointer(info.pointee.mCocoaAUViewBundleLocation.toOpaque())).takeRetainedValue() as URL
        // The class names follow the URL in memory as an array of CFStringRef.
        let classes = UnsafeRawPointer(raw + MemoryLayout<CFURL>.size).assumingMemoryBound(to: Unmanaged<CFString>.self)
        guard count > 0 else { return nil }
        let className = classes[0].takeRetainedValue() as String
        for index in 1..<count { _ = classes[index].takeRetainedValue() }

        guard let bundle = Bundle(url: bundleURL), bundle.load(),
              let factoryClass = bundle.classNamed(className) as? NSObject.Type else { return nil }
        let factory = factoryClass.init()
        guard factory.responds(to: #selector(SpectrumCocoaUIFactory.uiView(forAudioUnit:withSize:))) else { return nil }
        let typed = unsafeBitCast(factory, to: SpectrumCocoaUIFactory.self)
        return typed.uiView(forAudioUnit: au, withSize: NSSize(width: 0, height: 0))
    }

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

        // The plugin manages its own frame; a plain container lets us follow its size changes.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = []
        container.addSubview(view)
        window?.contentView = container
        window?.setContentSize(size)
        window?.setFrameAutosaveName("Plugin-\(slot.manufacturer)-\(slot.name)")
        if window?.frame.origin == .zero { window?.center() }

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

    /// Editor views released right after creation crash some plugins (their background initialisation is still
    /// running), so detached views are kept alive here for a couple of seconds before being released.
    private static var graveyard: [(Date, AnyObject)] = []

    func windowWillClose(_ notification: Notification) {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        pluginView?.removeFromSuperview()
        let now = Date()
        if let pluginView { Self.graveyard.append((now, pluginView)) }
        if let viewController { Self.graveyard.append((now, viewController)) }
        pluginView = nil
        viewController = nil
        window?.contentView = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            Self.graveyard.removeAll { $0.0 <= now }
        }
        onClose?()
    }

    func dispose() {
        window?.close()
    }
}
