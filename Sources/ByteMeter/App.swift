import SwiftUI

@main
struct ByteMeterApp: App {
    @StateObject private var store = UsageStore()

    init() {
        // Debug: BYTEMETER_SNAPSHOT=/path/panel.png renders the panel to a PNG and exits.
        if let out = ProcessInfo.processInfo.environment["BYTEMETER_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { Snapshot.render(to: out) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            UsageView().environmentObject(store)
        } label: {
            Text(store.menuBarText)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum Snapshot {
    static var store: UsageStore?
    static func render(to path: String) {
        let s = UsageStore()
        store = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let host = NSHostingView(rootView: UsageView().environmentObject(s))
            host.frame.size = host.fittingSize
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            win.appearance = NSAppearance(named: .aqua)
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Ölçülen liste yüksekliğiyle yeniden boyutlandır (menü penceresinin yaptığı gibi).
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                win.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                host.display()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }
}
