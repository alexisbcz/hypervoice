#if DEBUG
import AppKit

/// For checking the interface by eye: `HYPERVOICE_SNAPSHOT=/some/folder` saves a picture of the window
/// for every pane in `HYPERVOICE_PANES` (all by default), then quits. `HYPERVOICE_DRAFT` first generates
/// that text in Speech, the way the Generate button does; `HYPERVOICE_SCRIPT` generates the script instead.
enum Snapshot {
    static func runIfRequested(_ studio: Studio) {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["HYPERVOICE_SNAPSHOT"] else { return }
        let panes = environment["HYPERVOICE_PANES"]?.split(separator: ",").compactMap { Pane(rawValue: String($0)) } ?? Pane.allCases
        Task {
            try? await Task.sleep(for: .seconds(2))
            let offscreen = environment["HYPERVOICE_OFFSCREEN"] != nil
            if !offscreen {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
            }
            if environment["HYPERVOICE_SCRIPT"] != nil || environment["HYPERVOICE_DRAFT"] != nil {
                studio.section = environment["HYPERVOICE_SCRIPT"] != nil ? .script : .speech
                if let draft = environment["HYPERVOICE_DRAFT"] { studio.draft = draft }
                if let voice = environment["HYPERVOICE_VOICE"].flatMap(Library.shared.voice(named:)) { studio.voiceID = voice.id }
                studio.generate()
                try? await Task.sleep(for: .seconds(1))
                save(to: URL(fileURLWithPath: folder).appending(path: "generating.png"))
                while Generator.shared.isGenerating { try? await Task.sleep(for: .milliseconds(200)) }
                if let error = Generator.shared.error { try? error.write(toFile: folder + "/error.txt", atomically: true, encoding: .utf8) }
            }
            // Time to bring the window to the front from outside, since a background launch can't take focus.
            if let delay = environment["HYPERVOICE_CAPTURE_DELAY"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(delay))
            }
            for pane in panes {
                studio.section = pane
                if !offscreen, let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) {
                    window.makeKeyAndOrderFront(nil)
                    // No text cursor, and no stray keystrokes landing in the editor.
                    window.makeFirstResponder(nil)
                }
                try? await Task.sleep(for: .seconds(1.5))
                save(to: URL(fileURLWithPath: folder).appending(path: "\(pane.rawValue).png"))
            }
            if environment["HYPERVOICE_OPEN_SETTINGS"] != nil, let settings = NSApp.windows.first(where: { $0.frame.width <= 700 && $0.contentView != nil }),
               let view = settings.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appending(path: "settings.png"))
            }
            if environment["HYPERVOICE_STAY"] == nil { NSApp.terminate(nil) }
        }
    }

    /// The window as the screen shows it, shadow included. An app may capture its own windows
    /// without the Screen Recording permission.
    static func save(to url: URL) {
        // HYPERVOICE_OFFSCREEN draws the window's views without it ever reaching the screen
        // (launch with `open -j`), at the cost of the sidebar's glass, which only the window server draws.
        if ProcessInfo.processInfo.environment["HYPERVOICE_OFFSCREEN"] != nil {
            guard let view = NSApp.windows.first(where: { $0.frame.width > 400 })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            return
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let image = capture(CGWindowID(window.windowNumber))
        else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage`, looked up at run time since Swift no longer exposes it.
    private static func capture(_ window: CGWindowID) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageDefault.
        return create(.null, 1 << 3, window, 0)?.takeRetainedValue()
    }
}
#endif
