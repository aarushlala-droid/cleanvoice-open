import AppKit
import SwiftUI

/// Owns the app's state and its main window. The window is created here rather than by a SwiftUI WindowGroup,
/// because WindowGroup sometimes skipped creating the first window at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = EngineClient()
    let player = PlayerController()
    let claude = ClaudeAssistant()
    lazy var store = ProjectStore(engine: engine, player: player)
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)  // a dead engine pipe must produce an error, not kill the app
        if SelfTest.isRequested { SelfTest.say("app launched") }
        NSApp.setActivationPolicy(.regular)
        engine.start()
        showMainWindow()
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { engine.stop() }

    func showMainWindow() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let store = self.store, engine = self.engine, player = self.player
        let root = ContentView()
            .environmentObject(store)
            .environmentObject(engine)
            .environmentObject(player)
            .environmentObject(claude)
            .onAppear { SelfTest.runIfRequested(store: store, engine: engine, player: player) }
        let host = NSHostingController(rootView: root)
        host.sceneBridgingOptions = [.toolbars, .title]
        host.sizingOptions = []  // the window, not SwiftUI content, decides the window size
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
        w.title = "CleanVoice"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 1020, height: 640)
        w.setContentSize(NSSize(width: 1320, height: 820))
        w.center()
        w.setFrameAutosaveName("CleanVoiceMainWindow")
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

@main
struct CleanVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(delegate.engine)
                .environmentObject(delegate.claude)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                FileCommands(store: delegate.store, delegate: delegate)
            }
            CommandMenu("Clip") {
                ClipCommands(store: delegate.store, player: delegate.player)
            }
        }
    }
}

struct FileCommands: View {
    @ObservedObject var store: ProjectStore
    let delegate: AppDelegate
    var body: some View {
        Button("Add Folder or Clips…") { delegate.showMainWindow(); chooseMedia(store) }.keyboardShortcut("o")
        Button("Show Main Window") { delegate.showMainWindow() }.keyboardShortcut("1")
        Divider()
        Button("Clear Clip List") { store.removeAll() }.disabled(store.clips.isEmpty)
    }
}

struct ClipCommands: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var player: PlayerController
    var body: some View {
        Button("Play / Pause") { player.togglePlay() }
        Button(player.showCleaned ? "Listen to Original" : "Listen to Cleaned") { player.showCleaned.toggle() }
        Divider()
        Button("Previous Clip") { store.selectNext(-1) }
        Button("Next Clip") { store.selectNext(1) }
        Divider()
        Button("Export for DaVinci…") { store.showExportSheet = true }
            .keyboardShortcut("e")
            .disabled(store.clips.isEmpty)
        Button("Show Export Folder") { store.revealOutput() }
    }
}
