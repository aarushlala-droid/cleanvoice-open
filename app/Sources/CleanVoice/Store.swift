import AppKit
import AVFoundation
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class Clip: ObservableObject, Identifiable {
    enum Status { case waiting, working, ready, exported, failed }

    let id = UUID()
    let url: URL
    let root: URL
    @Published var status: Status = .waiting
    @Published var preview: PreviewResult?
    @Published var override: CleanSettings?
    @Published var progress: Double?
    @Published var error: String?
    @Published var exported: [String] = []
    @Published var thumbnail: NSImage?
    /// Most recent Auto result (kept when you pick a model by hand, so quality can still be compared).
    @Published var lastAuto: AutoInfo?
    var hasAppeared = false

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "mts", "m2ts", "avi", "mkv"]
    var isVideoGuess: Bool { preview?.analysis.hasVideo ?? Self.videoExtensions.contains(url.pathExtension.lowercased()) }

    init(url: URL, root: URL) {
        self.url = url
        self.root = root
    }

    func loadThumbnail() async {
        guard thumbnail == nil, isNativelyPlayable else { return }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 136)
        let d = (try? await asset.load(.duration).seconds) ?? 0
        if let img = try? await gen.image(at: CMTime(seconds: min(1, d / 2), preferredTimescale: 600)).image {
            thumbnail = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        }
    }

    var relativePath: String {
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : url.lastPathComponent
    }

    static let nativeExtensions: Set<String> = ["mp4", "mov", "m4v", "wav", "aif", "aiff", "mp3", "m4a", "flac"]
    var isNativelyPlayable: Bool { Self.nativeExtensions.contains(url.pathExtension.lowercased()) }
}

struct ExportOptions: Codable, Equatable {
    var video = true          // video files with the clean audio laid in
    var audio = true          // separate 24-bit WAVs
    var flat = false          // everything in one folder instead of mirroring source folders
    var sameNames = true      // keep original file names so DaVinci can relink

    static var saved: ExportOptions {
        get { UserDefaults.standard.data(forKey: "exportOptions").flatMap { try? JSONDecoder().decode(ExportOptions.self, from: $0) } ?? ExportOptions() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "exportOptions") }
    }
}

struct ProjectFile: Codable {
    var root: String
    var settings: CleanSettings
    var overrides: [String: CleanSettings]
    var outputDir: String?
}

@MainActor
final class ProjectStore: ObservableObject {
    static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "mts", "m2ts", "avi", "mkv",
                                               "wav", "bwf", "aif", "aiff", "flac", "mp3", "m4a"]

    @Published private(set) var clips: [Clip] = []
    @Published var selectionID: Clip.ID? { didSet { if selectionID != oldValue { selectionChanged() } } }
    @Published var projectSettings: CleanSettings = Defaults.settings
    @Published var outputDir: URL? { didSet { scheduleSave() } }
    @Published var exportOptions = ExportOptions.saved { didSet { ExportOptions.saved = exportOptions } }
    @Published private(set) var exportProgress: (done: Int, total: Int)?
    @Published private(set) var exportCurrent: String?
    @Published private(set) var lastExport: (count: Int, failed: Int, folder: URL)?
    @Published var banner: String?
    @Published private(set) var undoSnapshot: (settings: CleanSettings, overrides: [UUID: CleanSettings?], label: String)?

    let engine: EngineClient
    let player: PlayerController
    private var previewTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var userPreviewInFlight = false
    private var exporting = false

    init(engine: EngineClient, player: PlayerController) {
        self.engine = engine
        self.player = player
        player.onStep = { [weak self] step in self?.selectNext(step) }
    }

    @Published var showExportSheet = false

    var selected: Clip? { clips.first { $0.id == selectionID } }
    var preparedCount: Int { clips.filter { $0.preview != nil }.count }
    var isExporting: Bool { exporting }

    func selectNext(_ step: Int) {
        guard !clips.isEmpty else { return }
        let i = clips.firstIndex { $0.id == selectionID } ?? -step
        selectionID = clips[max(0, min(clips.count - 1, i + step))].id
    }
    var primaryRoot: URL? { clips.first?.root }

    func effective(_ clip: Clip) -> CleanSettings { clip.override ?? projectSettings }

    // MARK: Settings editing (bound to the inspector)

    /// Settings for the inspector: the selected clip's own settings if it has them, otherwise the project's.
    var editing: CleanSettings {
        get { selected.map(effective) ?? projectSettings }
        set {
            if let c = selected, c.override != nil {
                c.override = newValue
            } else {
                projectSettings = newValue
            }
            objectWillChange.send()
            settingsDidChange()
        }
    }

    var clipOnly: Bool {
        get { selected?.override != nil }
        set {
            guard let c = selected else { return }
            c.override = newValue ? projectSettings : nil
            objectWillChange.send()
            settingsDidChange()
        }
    }

    func resetToDefaults() { editing = Defaults.settings }

    func saveAsDefaults() {
        Defaults.settings = editing
        banner = "Saved as your default settings for new projects."
    }

    func resetDefaultsToFactory() {
        Defaults.resetToFactory()
        banner = "Defaults reset to the original values (room tone, cinema -24 LUFS)."
    }

    private func settingsDidChange() {
        if let c = selected, c.preview != nil, c.status != .working { c.status = .working }
        schedulePreview(debounce: true)
        scheduleSave()
        // Clips that follow the project settings need re-preparing in the background.
        restartBackground()
    }

    // MARK: Claude changes (undoable)

    func applyChanges(_ changes: [String: Any], scope: String, label: String) {
        let snap = (projectSettings, Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.override) }), label)
        if scope == "clip", let c = selected {
            c.override = effective(c).applying(changes)
        } else {
            projectSettings = projectSettings.applying(changes)
            if let c = selected, c.override != nil { c.override = c.override!.applying(changes) }
        }
        undoSnapshot = snap
        objectWillChange.send()
        settingsDidChange()
    }

    func undoLastChange() {
        guard let s = undoSnapshot else { return }
        projectSettings = s.settings
        for c in clips { if let o = s.overrides[c.id] { c.override = o } }
        undoSnapshot = nil
        objectWillChange.send()
        settingsDidChange()
    }

    // MARK: Adding clips

    func add(urls: [URL]) {
        var added: [Clip] = []
        let existing = Set(clips.map { $0.url.standardizedFileURL.path })
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                for f in scan(folder: url) where !existing.contains(f.standardizedFileURL.path) {
                    added.append(Clip(url: f, root: url))
                }
            } else if Self.mediaExtensions.contains(url.pathExtension.lowercased()), !existing.contains(url.standardizedFileURL.path) {
                added.append(Clip(url: url, root: url.deletingLastPathComponent()))
            }
        }
        guard !added.isEmpty else {
            banner = "No video or audio files found there."
            return
        }
        let wasEmpty = clips.isEmpty
        let sorted = added.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clips.append(contentsOf: sorted)
        } else {
            withAnimation(.default) { clips.append(contentsOf: sorted) }
        }
        if wasEmpty { loadProject() }
        for c in added { applySavedOverride(c) }
        Task { for c in added { await c.loadThumbnail() } }
        if selectionID == nil { selectionID = clips.first?.id }
        restartBackground()
    }

    private func scan(folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            // Skip CleanVoice's own export folders (they hold files with the same names as the originals).
            if url.lastPathComponent == Self.exportFolderName || url.lastPathComponent == "cleaned"
                || FileManager.default.fileExists(atPath: url.appendingPathComponent(".cleanvoice-manifest.json").path) {
                e.skipDescendants(); continue
            }
            guard Self.mediaExtensions.contains(url.pathExtension.lowercased()),
                  !url.deletingPathExtension().lastPathComponent.contains("_clean") else { continue }
            out.append(url)
        }
        return out
    }

    func remove(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        if selectionID == clip.id { selectionID = clips.first?.id }
        if clips.isEmpty { player.clear() }
    }

    func removeAll() {
        previewTask?.cancel()
        backgroundTask?.cancel()
        clips.removeAll()
        selectionID = nil
        player.clear()
        undoSnapshot = nil
        projectSettings = Defaults.settings
        outputDir = nil
    }

    // MARK: Previews

    private func selectionChanged() {
        guard let c = selected else { player.clear(); return }
        Task { await player.load(clip: c) }
        schedulePreview(debounce: false)
    }

    func schedulePreview(debounce: Bool) {
        previewTask?.cancel()
        guard let clip = selected else { return }
        previewTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            await self?.renderPreview(clip)
        }
    }

    private func renderPreview(_ clip: Clip) async {
        let settings = effective(clip)
        if clip.preview != nil, clip.preview?.settingsHash == settingsKey(clip, settings), clip.status != .failed {
            await player.load(clip: clip)
            return
        }
        userPreviewInFlight = true
        defer { userPreviewInFlight = false }
        await prepare(clip, settings: settings, user: true)
        if selectionID == clip.id { await player.load(clip: clip) }
    }

    private var hashes: [UUID: (CleanSettings, String)] = [:]
    private func settingsKey(_ clip: Clip, _ s: CleanSettings) -> String? {
        guard let h = hashes[clip.id], h.0 == s else { return nil }
        return h.1
    }

    /// Render a clip's preview with the given settings (engine caches heavy stages, so repeats are fast).
    private func prepare(_ clip: Clip, settings: CleanSettings, user: Bool) async {
        if clip.status != .exported || user { clip.status = .working }
        clip.progress = 0
        clip.error = nil
        do {
            let r = try await engine.request("preview", [
                "path": clip.url.path, "settings": settings.engineJSON, "original": !clip.isNativelyPlayable,
            ], progress: { [weak clip] v in clip?.progress = v })
            let res = try decodeEngine(PreviewResult.self, r)
            guard effective(clip) == settings else { clip.progress = nil; return }  // settings moved on; newer render follows
            hashes[clip.id] = (settings, res.settingsHash)
            clip.preview = res
            if let a = res.stats.auto { clip.lastAuto = a }
            if selectionID == clip.id { objectWillChange.send() }  // inspector shows the selected clip's results
            clip.progress = nil
            clip.status = clip.exported.isEmpty ? .ready : .exported
        } catch {
            clip.progress = nil
            clip.status = .failed
            clip.error = error.localizedDescription
        }
    }

    /// Prepare every clip in turn so switching clips is instant and Auto has picked each clip's model.
    private func restartBackground() {
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            while let self, !Task.isCancelled {
                if self.userPreviewInFlight || self.exporting || Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                guard let next = self.clips.first(where: { c in
                    c.status != .working && c.status != .failed && self.settingsKey(c, self.effective(c)) == nil
                }) else { return }
                await self.prepare(next, settings: self.effective(next), user: false)
            }
        }
    }

    // MARK: Export

    static let exportFolderName = "Cleaned for DaVinci"

    func outputFolder(for clip: Clip) -> URL {
        outputDir ?? clip.root.appendingPathComponent(Self.exportFolderName)
    }

    func export(_ targets: [Clip]) async {
        guard !exporting, !targets.isEmpty else { return }
        exporting = true
        exportProgress = (0, targets.count)
        lastExport = nil
        var failed = 0
        let o = exportOptions
        for (i, clip) in targets.enumerated() {
            exportCurrent = clip.url.lastPathComponent
            clip.status = .working
            clip.progress = 0
            do {
                let r = try await engine.request("export", [
                    "path": clip.url.path, "settings": effective(clip).engineJSON,
                    "out_dir": outputFolder(for: clip).path, "root": clip.root.path,
                    "video": o.video, "wav_stem": o.audio, "layout": o.flat ? "flat" : "folders", "same_names": o.sameNames,
                ], progress: { [weak clip] v in clip?.progress = v })
                let res = try decodeEngine(ExportResult.self, r)
                clip.exported = res.outputs
                clip.status = .exported
                clip.error = nil
            } catch {
                failed += 1
                clip.status = .failed
                clip.error = "Export failed: \(error.localizedDescription)"
            }
            clip.progress = nil
            exportProgress = (i + 1, targets.count)
        }
        exporting = false
        exportProgress = nil
        exportCurrent = nil
        if let first = targets.first { lastExport = (targets.count, failed, outputFolder(for: first)) }
        restartBackground()
    }

    func resetLastExport() { lastExport = nil }

    func revealOutput() {
        guard let c = selected ?? clips.first else { return }
        let f = outputFolder(for: c)
        if FileManager.default.fileExists(atPath: f.path) {
            NSWorkspace.shared.activateFileViewerSelecting([f])
        } else {
            banner = "Nothing exported yet. The output folder will be \(f.path)"
        }
    }

    // MARK: Project persistence (Application Support; nothing is written next to your footage until you export)

    private func projectURL(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanVoice/projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(String(digest.prefix(24)) + ".json")
    }

    private var savedOverrides: [String: CleanSettings] = [:]

    private func loadProject() {
        guard let root = primaryRoot,
              let data = try? Data(contentsOf: projectURL(for: root)),
              let p = try? JSONDecoder().decode(ProjectFile.self, from: data) else { savedOverrides = [:]; return }
        projectSettings = p.settings
        savedOverrides = p.overrides
        outputDir = p.outputDir.map { URL(fileURLWithPath: $0) }
        banner = "Restored your settings for this folder."
    }

    private func applySavedOverride(_ c: Clip) {
        if let o = savedOverrides[c.relativePath] { c.override = o }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled, let root = self.primaryRoot else { return }
            var overrides: [String: CleanSettings] = [:]
            for c in self.clips where c.root == root { if let o = c.override { overrides[c.relativePath] = o } }
            let p = ProjectFile(root: root.path, settings: self.projectSettings, overrides: overrides, outputDir: self.outputDir?.path)
            if let data = try? JSONEncoder().encode(p) { try? data.write(to: self.projectURL(for: root), options: .atomic) }
        }
    }
}
