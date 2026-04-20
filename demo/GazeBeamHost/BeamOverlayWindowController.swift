import AppKit
import SwiftUI

@MainActor
final class BeamOverlayWindowController {
    private let model: BeamOverlayModel
    private var windows: [NSWindow] = []

    init(model: BeamOverlayModel) {
        self.model = model
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshWindows()
            }
        }
    }

    func show() {
        if windows.isEmpty {
            refreshWindows()
        }
        for window in windows {
            window.orderFrontRegardless()
        }
    }

    func setVisible(_ isVisible: Bool) {
        if isVisible {
            show()
            return
        }
        for window in windows {
            window.orderOut(nil)
        }
    }

    private func refreshWindows() {
        for window in windows {
            window.close()
        }
        windows = NSScreen.screens.map(makeWindow(for:))
        for window in windows {
            window.orderFrontRegardless()
        }
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = BeamOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: BeamOverlayRootView(model: model, screenFrame: screen.frame))
        return window
    }
}

private final class BeamOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
