import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Plays the original video with two audio tracks (original and cleaned) and switches between them instantly,
/// keeping the playhead. Nothing is re-encoded: the cleaned WAV is laid against the source in a composition.
@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var showCleaned = true { didSet { applyMix() } }
    @Published var matchLoudness = true { didSet { applyMix() } }
    @Published private(set) var notice: String?
    @Published private(set) var hasVideo = false
    @Published private(set) var isPlaying = false
    private var rateObservation: NSKeyValueObservation?

    private var currentAssets: [AVAsset] = []
    private var originalTrack: AVAssetTrack?
    private var cleanedTrack: AVAssetTrack?
    private var originalGain: Float = 1
    private var cleanedGain: Float = 1
    private var loadedKey: String?
    private var loadedClip: URL?
    private var keyMonitor: Any?
    /// Up/Down arrow: previous/next clip (set by the store).
    var onStep: ((Int) -> Void)?

    init() {
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.isPlaying = playing } }
        }
        // A toggles original/cleaned, Space plays/pauses — except while typing in a text field.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            if event.keyCode == 125 { self.onStep?(1); return nil }   // down arrow
            if event.keyCode == 126 { self.onStep?(-1); return nil }  // up arrow
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": self.showCleaned.toggle(); return nil
            case " ": self.togglePlay(); return nil
            default: return event
            }
        }
    }

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    func clear() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedKey = nil
        loadedClip = nil
        notice = nil
    }

    private var generation = 0

    /// Load (or refresh) a clip's preview. Keeps position and play state when only the cleaned audio changed.
    /// Loads are serialised by a generation counter so overlapping requests can never mix up tracks.
    func load(clip: Clip) async {
        guard let preview = clip.preview else { clear(); return }
        let key = clip.url.path + "|" + preview.wav
        if key == loadedKey { return }
        generation += 1
        let gen = generation
        let sameClip = loadedClip == clip.url
        let wasPlaying = player.rate != 0
        let time = player.currentTime()
        do {
            let built = try await Self.build(clipURL: clip.url, native: clip.isNativelyPlayable, preview: preview)
            guard gen == generation else { return }  // a newer load started meanwhile
            currentAssets = built.assets
            originalTrack = built.original
            cleanedTrack = built.cleaned
            hasVideo = built.hasVideo
            originalGain = built.originalGain
            cleanedGain = built.cleanedGain
            notice = built.notice
            player.replaceCurrentItem(with: built.item)
            applyMix()
            loadedKey = key
            loadedClip = clip.url
            if sameClip {
                await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { player.play() }
            }
        } catch {
            guard gen == generation else { return }
            let ns = error as NSError
            let under = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " / \($0.domain) \($0.code)" } ?? ""
            notice = "Preview could not be loaded (\(ns.domain) \(ns.code)\(under)): \(ns.localizedDescription)"
            lastError = notice
        }
    }

    @Published private(set) var lastError: String?

    private struct Built {
        let item: AVPlayerItem
        let original: AVAssetTrack?
        let cleaned: AVAssetTrack
        let hasVideo: Bool
        let originalGain: Float
        let cleanedGain: Float
        let notice: String?
        /// The source assets must outlive the composition: an AVAssetTrack becomes invalid once its asset is
        /// released (optimised builds release locals early), which made previews fail with -11800/-12780.
        let assets: [AVAsset]
    }

    private static func build(clipURL: URL, native: Bool, preview: PreviewResult) async throws -> Built {
        let comp = AVMutableComposition()
        var assets: [AVAsset] = []
        let cleanedAsset = AVURLAsset(url: URL(fileURLWithPath: preview.wav))
        assets.append(cleanedAsset)
        guard let cleanedSource = try await cleanedAsset.loadTracks(withMediaType: .audio).first else {
            throw EngineError(message: "cleaned audio has no track")
        }
        let cleanedRange = try await cleanedSource.load(.timeRange)
        var duration = cleanedRange.duration
        var originalSource: AVAssetTrack?
        var videoSource: AVAssetTrack?
        var notice: String?
        if native {
            let src = AVURLAsset(url: clipURL)
            assets.append(src)
            videoSource = try await src.loadTracks(withMediaType: .video).first
            originalSource = try await src.loadTracks(withMediaType: .audio).first
            if let v = videoSource { duration = try await v.load(.timeRange).duration }
        } else {
            if let ow = preview.originalWav {
                let a = AVURLAsset(url: URL(fileURLWithPath: ow))
                assets.append(a)
                originalSource = try await a.loadTracks(withMediaType: .audio).first
            }
            if preview.analysis.hasVideo {
                notice = "Video preview isn't available for .\(clipURL.pathExtension) files. You can still compare the audio, and export copies the video as normal."
            }
        }
        if let v = videoSource, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let r = try await v.load(.timeRange)
            try t.insertTimeRange(r, of: v, at: .zero)
            t.preferredTransform = try await v.load(.preferredTransform)
        }
        var originalTrack: AVAssetTrack?
        if let o = originalSource, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let r = try await o.load(.timeRange)
            try t.insertTimeRange(CMTimeRange(start: r.start, duration: CMTimeMinimum(r.duration, duration)), of: o, at: .zero)
            originalTrack = t
        }
        guard let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EngineError(message: "could not create audio track")
        }
        try ct.insertTimeRange(CMTimeRange(start: cleanedRange.start, duration: CMTimeMinimum(cleanedRange.duration, duration)),
                               of: cleanedSource, at: .zero)

        // Loudness-matched comparison: turn down whichever version is louder so A/B judges cleanliness, not volume.
        let g = Float(pow(10, (preview.stats.lufs - preview.analysis.lufs) / 20))
        return Built(item: AVPlayerItem(asset: comp), original: originalTrack, cleaned: ct, hasVideo: videoSource != nil,
                     originalGain: g < 1 ? g : 1, cleanedGain: g > 1 ? 1 / g : 1, notice: notice, assets: assets)
    }

    private func applyMix() {
        guard let item = player.currentItem else { return }
        var params: [AVMutableAudioMixInputParameters] = []
        if let o = originalTrack {
            let p = AVMutableAudioMixInputParameters(track: o)
            p.setVolume(showCleaned ? 0 : (matchLoudness ? originalGain : 1), at: .zero)
            params.append(p)
        }
        if let c = cleanedTrack {
            let p = AVMutableAudioMixInputParameters(track: c)
            p.setVolume(showCleaned ? (matchLoudness ? cleanedGain : 1) : 0, at: .zero)
            params.append(p)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        item.audioMix = mix
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        v.videoGravity = .resizeAspect
        // Never let the video's natural size (e.g. 3840×2160) drive layout: it caused a split-view layout loop.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            v.setContentHuggingPriority(.defaultLow - 1, for: axis)
            v.setContentCompressionResistancePriority(.defaultLow - 1, for: axis)
        }
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }

    /// Always take exactly the space offered.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 640, height: 360))
    }
}
