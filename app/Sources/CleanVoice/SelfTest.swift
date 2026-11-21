import AppKit
import AVFoundation
import Foundation
import SwiftUI

/// Automated end-to-end check, run only with `--selftest <folder> <report-dir>`.
/// Loads the folder, waits for every clip, flips A/B, moves settings, uses a clip-only override, exports, snapshots the window.
@MainActor
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }
    static func say(_ s: String) {
        let line = Data("selftest: \(s)\n".utf8)
        FileHandle.standardError.write(line)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), args.count > i + 2 {
            let url = URL(fileURLWithPath: args[i + 2]).appendingPathComponent("log.txt")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
            else { try? line.write(to: url) }
        }
    }

    static func runIfRequested(store: ProjectStore, engine: EngineClient, player: PlayerController) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2 else { return }
        say("started")
        let folder = URL(fileURLWithPath: args[i + 1]), reportDir = URL(fileURLWithPath: args[i + 2])
        Task { await run(folder: folder, reportDir: reportDir, store: store, engine: engine, player: player) }
    }

    private static func wait(_ seconds: Double, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return cond()
    }

    private static func snapshot(_ name: String, _ dir: URL, sheet: Bool = false) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        let win = sheet ? windows.first(where: { $0.isSheet }) : windows.first(where: { !$0.isSheet })
        // The content view's superview is the window frame, so the title bar and toolbar are included.
        guard let view = win?.contentView?.superview ?? win?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }

    /// Describes every scroll view in the window: where it is, how big its content is and what it holds.
    static func describeScrollViews() -> [String] {
        guard let root = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet })?.contentView else { return ["no window"] }
        var out: [String] = []
        func walk(_ v: NSView, _ depth: Int) {
            if let sv = v as? NSScrollView {
                let doc = sv.documentView
                let r = sv.convert(sv.bounds, to: nil)
                out.append("scroll at x=\(Int(r.minX)) w=\(Int(r.width)) h=\(Int(r.height)) doc=\(doc.map { "\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height)) subviews=\($0.subviews.count) docOrigin=\(Int($0.frame.minY)) visible=\(Int($0.visibleRect.minY))..\(Int($0.visibleRect.maxY))" } ?? "nil") clipBounds.y=\(Int(sv.contentView.bounds.minY)) insets.top=\(Int(sv.contentInsets.top)) flipped=\(sv.documentView?.isFlipped ?? false)")
            }
            for s in v.subviews { walk(s, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    /// Offscreen render of the clip list (the window snapshot can't capture the sidebar's contents).
    static func renderClipList(store: ProjectStore, to url: URL) {
        let view = VStack(spacing: 4) {
            ForEach(Array(store.clips.enumerated()), id: \.element.id) { i, clip in
                ClipCard(clip: clip, selected: clip.id == store.selectionID, index: i)
            }
        }
        .padding(8)
        .frame(width: 290)
        .background(Color(nsColor: .windowBackgroundColor))
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private static func volumes(_ player: PlayerController) -> [Float] {
        (player.player.currentItem?.audioMix?.inputParameters ?? []).map { p in
            var start: Float = -1, end: Float = -1
            var range = CMTimeRange()
            _ = p.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)
            return start
        }
    }

    static func run(folder: URL, reportDir: URL, store: ProjectStore, engine: EngineClient, player: PlayerController) async {
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        var log: [String: Any] = [:]
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool, _ detail: Any = "") {
            checks.append(["check": name, "ok": ok, "detail": "\(detail)"])
            say("\(ok ? "PASS" : "FAIL") \(name): \(detail)")
        }
        let t0 = Date()
        check("engine ready", await wait(60) { engine.state == .ready }, engine.state)
        try? await Task.sleep(nanoseconds: 800_000_000)
        snapshot("0-empty.png", reportDir)
        store.add(urls: [folder])
        check("clips found", !store.clips.isEmpty, store.clips.map(\.relativePath))
        let allPrepared = await wait(300) { store.clips.allSatisfy { $0.preview != nil || $0.status == .failed } }
        check("all clips prepared", allPrepared, store.clips.map { "\($0.relativePath): \($0.preview?.stats.model ?? $0.error ?? "-")" })
        log["prepare_seconds"] = Date().timeIntervalSince(t0)

        // Player has the selected clip with two audio tracks; A/B flips volumes.
        let loaded = await wait(15) { player.player.currentItem != nil }
        check("player loaded selected clip", loaded, "\(store.selected?.relativePath ?? "-") error=\(player.lastError ?? "none")")
        // Real playback: the playhead must move and the item must be ready, for an audio clip and a video clip.
        func playCheck(_ label: String) async {
            await player.player.seek(to: .zero)
            player.player.play()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let item = player.player.currentItem
            let t = player.player.currentTime().seconds
            check("plays \(label)", item?.status == .readyToPlay && item?.error == nil && t > 0.8,
                  "status=\(item?.status.rawValue ?? -1) time=\(String(format: "%.2f", t)) video=\(player.hasVideo) err=\(item?.error?.localizedDescription ?? player.lastError ?? "none")")
            player.player.pause()
        }
        await playCheck("selected clip \(store.selected?.relativePath ?? "-")")
        if let video = store.clips.first(where: { $0.url.pathExtension.lowercased() == "mp4" }) {
            store.selectionID = video.id
            _ = await wait(15) { player.player.currentItem != nil && player.hasVideo }
            await playCheck("video clip \(video.relativePath)")
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        snapshot("1-loaded.png", reportDir)
        for line in describeScrollViews() { say("view: \(line)") }
        renderClipList(store: store, to: reportDir.appendingPathComponent("1b-clip-list.png"))
        if CommandLine.arguments.contains("--pause") {
            say("PAUSED")
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        player.matchLoudness = false
        player.showCleaned = true
        let cleanedVols = volumes(player)
        player.showCleaned = false
        let originalVols = volumes(player)
        check("A/B switches tracks", cleanedVols.count == 2 && cleanedVols == [0, 1] && originalVols == [1, 0],
              "cleaned \(cleanedVols) original \(originalVols)")
        player.matchLoudness = true
        player.showCleaned = true
        check("loudness-matched volumes", volumes(player).allSatisfy { $0 >= 0 && $0 <= 1 }, volumes(player))

        // Moving a slider re-renders the selected clip's preview.
        guard let clip = store.selected else { check("selection", false); return finish(log, checks, reportDir) }
        let before = clip.preview?.settingsHash
        var s = store.editing
        s.clarity = 4.5
        store.editing = s
        let rerendered = await wait(30) { clip.preview?.settingsHash != before && clip.status != .working }
        check("slider change re-renders", rerendered, "\(before ?? "-") -> \(clip.preview?.settingsHash ?? "-")")

        // Clip-only override with a different model.
        store.clipOnly = true
        s = store.editing
        s.model = "spectral"
        store.editing = s
        let overridden = await wait(30) { clip.preview?.stats.model == "spectral" && clip.status != .working }
        check("clip-only override uses its own model", overridden && store.projectSettings.model == "auto",
              "clip=\(clip.preview?.stats.model ?? "-") project=\(store.projectSettings.model)")
        store.clipOnly = false

        // Claude-style change and undo.
        store.applyChanges(["noise_reduction": 18, "warmth": 1.5], scope: "all", label: "test change")
        let applied = store.projectSettings.noiseReduction == 18 && store.projectSettings.warmth == 1.5
        store.undoLastChange()
        check("apply + undo changes", applied && store.projectSettings.noiseReduction == 28, store.projectSettings.noiseReduction)

        _ = await wait(30) { clip.status != .working }
        snapshot("2-adjusted.png", reportDir)

        // Export everything to a test folder, through the export sheet.
        store.outputDir = reportDir.appendingPathComponent("exports")
        store.showExportSheet = true
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        snapshot("3-export-sheet.png", reportDir, sheet: true)
        await store.export(store.clips)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        snapshot("4-export-done.png", reportDir, sheet: true)
        store.showExportSheet = false
        let outputs = store.clips.flatMap(\.exported)
        check("export all", store.clips.allSatisfy { $0.status == .exported || $0.preview?.stats.littleSpeech == true }
              && outputs.allSatisfy { FileManager.default.fileExists(atPath: $0) }, outputs)
        try? await Task.sleep(nanoseconds: 600_000_000)
        snapshot("5-after-export.png", reportDir)
        log["total_seconds"] = Date().timeIntervalSince(t0)
        finish(log, checks, reportDir)
    }

    private static func finish(_ log: [String: Any], _ checks: [[String: Any]], _ dir: URL) {
        var out = log
        out["checks"] = checks
        out["passed"] = checks.allSatisfy { $0["ok"] as? Bool == true }
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("report.json"))
        }
        NSApp.terminate(nil)
    }
}
