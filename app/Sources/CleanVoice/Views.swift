import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Motion

/// Timings follow the app's motion rules: frequent, small feedback is fast (≤150 ms); entering content eases out;
/// exits are quicker than entries; everything collapses to a short fade when Reduce Motion is on.
enum Motion {
    static let quick = Animation.easeOut(duration: 0.12)
    static let enter = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.26)
    static let exit = Animation.timingCurve(0.7, 0, 0.84, 0, duration: 0.12)
    static let settle = Animation.spring(response: 0.32, dampingFraction: 0.8)
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let animation: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduce ? .easeOut(duration: 0.1) : animation, value: value)
    }
}

extension View {
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

/// Local view state held in an ObservableObject. (The Command Line Tools ship without SwiftUI's macro plugin,
/// so `@State` cannot be expanded when building without Xcode.)
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @StateObject private var showInspector = Box(true)
    @StateObject private var dropTargeted = Box(false)

    var body: some View {
        NavigationSplitView {
            ClipListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 420)
        } detail: {
            DetailView()
                .inspector(isPresented: $showInspector.value) {
                    ControlsView()
                        .inspectorColumnWidth(min: 310, ideal: 350, max: 460)
                }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { chooseMedia(store) } label: { Label("Add Clips", systemImage: "plus") }
                    .help("Add a folder or clips (⌘O)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.showExportSheet = true } label: {
                    Label("Export for DaVinci", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.clips.isEmpty)
                .help("Export every clip with clean audio into simple folders for DaVinci Resolve (⌘E)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.value.toggle() } label: { Label("Adjust", systemImage: "slider.horizontal.3") }
                    .help("Show or hide the sound controls")
            }
        }
        .sheet(isPresented: $store.showExportSheet) { ExportSheet() }
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls: urls)
            return true
        } isTargeted: { dropTargeted.value = $0 }
        .overlay {
            if dropTargeted.value {
                DropHighlight().transition(.opacity)
            }
        }
        .motion(Motion.quick, value: dropTargeted.value)
    }
}

struct DropHighlight: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [12, 7]))
                .padding(10)
            Label("Drop to add clips", systemImage: "plus.circle.fill")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
        }
        .allowsHitTesting(false)
    }
}

@MainActor
func chooseMedia(_ store: ProjectStore) {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = true
    p.allowsMultipleSelection = true
    p.allowedContentTypes = [.folder, .movie, .audio, .mpeg4Movie, .quickTimeMovie, .wav]
    p.prompt = "Add"
    p.message = "Choose folders or clips. Use source clips, not a finished mix: music and sound effects would be removed too."
    if p.runModal() == .OK { store.add(urls: p.urls) }
}

// MARK: - Clip list

struct ClipListView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(store.clips.enumerated()), id: \.element.id) { index, clip in
                        ClipCard(clip: clip, selected: clip.id == store.selectionID, index: index)
                            .id(clip.id)
                            .onTapGesture { store.selectionID = clip.id }
                            .contextMenu {
                                Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
                                if let out = clip.exported.first {
                                    Button("Show Export in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: out)]) }
                                }
                                Divider()
                                Button("Remove from List") { store.remove(clip) }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: store.selectionID) { _, id in
                guard let id else { return }
                withAnimation(Motion.enter) { proxy.scrollTo(id) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("Clips").font(.headline)
                Spacer()
                if !store.clips.isEmpty {
                    Text("\(store.clips.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
        }
        .overlay {
            if store.clips.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("Your clips appear here").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { chooseMedia(store) } label: {
                Label("Add Clips…", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(10)
            .background(.bar)
        }
    }
}

struct ClipCard: View {
    @ObservedObject var clip: Clip
    let selected: Bool
    let index: Int
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(clip: clip)
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                StatusLine(clip: clip)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.17) : (hover.value ? Color.primary.opacity(0.05) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .motion(Motion.quick, value: selected)
        .motion(Motion.quick, value: hover.value)
        // Staggered entrance when clips are added: 40 ms apart, the rest together after 8 items. Cards are visible
        // by default; only the insertion animates.
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)).animation(Motion.enter.delay(Double(min(index, 8)) * 0.04)),
            removal: .opacity.animation(Motion.exit)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

struct Thumbnail: View {
    @ObservedObject var clip: Clip

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = clip.thumbnail {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.32), Color(red: 0.1, green: 0.34, blue: 0.42)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: clip.isVideoGuess ? "film" : "waveform").foregroundStyle(.white.opacity(0.7)))
                }
            }
            .frame(width: 76, height: 43)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if let d = clip.preview?.analysis.duration {
                Text(durationText(d))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .padding(3)
            }
        }
    }
}

func durationText(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

struct StatusLine: View {
    @ObservedObject var clip: Clip

    var body: some View {
        HStack(spacing: 5) {
            switch clip.status {
            case .working:
                if clip.preview == nil, let p = clip.progress {
                    ProgressView(value: p).progressViewStyle(.linear).frame(width: 54).controlSize(.mini)
                    Text("Cleaning").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                    Text(clip.preview == nil ? "Cleaning" : "Updating").foregroundStyle(.secondary)
                }
            case .ready:
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Ready · " + shortModel(clip.preview?.stats.model ?? "")).foregroundStyle(.secondary)
                if let w = clip.preview?.stats.warnings, !w.isEmpty {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help(w.joined(separator: "\n"))
                }
            case .exported:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Exported").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Problem, see details").foregroundStyle(.orange)
            case .waiting:
                Text("Waiting").foregroundStyle(.tertiary)
            }
            if clip.override != nil {
                Image(systemName: "slider.horizontal.below.rectangle").foregroundStyle(.secondary).help("Has its own settings")
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

func shortModel(_ id: String) -> String {
    ["deepfilternet3": "DeepFilterNet 3", "deepfilternet2": "DeepFilterNet 2", "rnnoise": "RNNoise", "spectral": "Spectral"][id] ?? id
}

func fmt(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: "-", with: "−") }

// MARK: - Step header

struct StepHeader: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        let total = store.clips.count, ready = store.preparedCount
        let exported = store.lastExport != nil
        HStack(spacing: 8) {
            StepPill(number: 1, title: total == 0 ? "Add clips" : "\(total) clip\(total == 1 ? "" : "s") added",
                     state: total > 0 ? .done : .current) { chooseMedia(store) }
            StepArrow()
            StepPill(number: 2, title: total == 0 ? "Review" : (ready < total ? "Cleaning \(ready) of \(total)…" : "Review & adjust"),
                     state: total == 0 ? .todo : (exported ? .done : .current),
                     progress: total > 0 && ready < total ? Double(ready) / Double(total) : nil) {}
            StepArrow()
            StepPill(number: 3, title: exported ? "Exported" : "Export for DaVinci",
                     state: exported ? .done : (total > 0 && ready == total ? .current : .todo)) {
                if total > 0 { store.showExportSheet = true }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct StepArrow: View {
    var body: some View { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
}

struct StepPill: View {
    enum State { case todo, current, done }
    let number: Int
    let title: String
    let state: State
    var progress: Double? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(state == .todo ? Color.secondary.opacity(0.2) : (state == .done ? Color.green : Color.accentColor))
                    if let p = progress {
                        Circle().trim(from: 0, to: p).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(3)
                    } else if state == .done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.system(size: 10, weight: .bold)).foregroundStyle(state == .todo ? Color.secondary : .white)
                    }
                }
                .frame(width: 18, height: 18)
                Text(title)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: state == .current ? .semibold : .regular))
                    .foregroundStyle(state == .todo ? .secondary : .primary)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(state == .current ? Color.accentColor.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .motion(Motion.enter, value: title)
        .motion(Motion.quick, value: progress)
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        VStack(spacing: 0) {
            StepHeader()
            EngineStatusBar()
            if let b = store.banner {
                BannerView(text: b) { store.banner = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if store.clips.isEmpty {
                EmptyStateView()
            } else if let clip = store.selected {
                ClipDetail(clip: clip)
            } else {
                Text("Select a clip").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .motion(Motion.enter, value: store.banner)
        .navigationTitle(store.selected?.url.lastPathComponent ?? "CleanVoice")
    }
}

struct ClipDetail: View {
    @ObservedObject var clip: Clip
    @EnvironmentObject var player: PlayerController

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerSurface(player: player.player)
                if clip.preview == nil {
                    CleaningCard(clip: clip).transition(.opacity)
                } else if !player.hasVideo {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 56, weight: .light))
                        Text("Audio clip").font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.35))
                    .allowsHitTesting(false)
                }
                if let n = player.notice {
                    VStack {
                        Spacer()
                        Label(n, systemImage: "info.circle").font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(.bottom, 52)
                    }
                }
            }
            .frame(minHeight: 300)
            .motion(Motion.enter, value: clip.preview == nil)
            ListenBar(clip: clip)
            ResultsStrip(clip: clip)
        }
    }
}

struct CleaningCard: View {
    @ObservedObject var clip: Clip

    var body: some View {
        VStack(spacing: 12) {
            if clip.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(.orange)
                Text(clip.error ?? "This clip could not be cleaned.").multilineTextAlignment(.center)
            } else {
                ProgressView(value: clip.progress ?? 0).frame(width: 240).motion(Motion.quick, value: clip.progress)
                Text("Cleaning… trying each model and keeping the best").font(.callout)
                Text("Usually a few seconds per clip").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

struct ListenBar: View {
    @ObservedObject var clip: Clip
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        HStack(spacing: 14) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help("Play / pause (Space)")
            .disabled(clip.preview == nil)

            ABSwitch(cleaned: $player.showCleaned)
                .disabled(clip.preview == nil)
            HStack(spacing: 4) {
                KeyCap("A")
                Text("to compare").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(-1)

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            }
            .opacity(clip.status == .working && clip.preview != nil ? 1 : 0)
            .accessibilityHidden(!(clip.status == .working && clip.preview != nil))
            Spacer(minLength: 8)
            Toggle("Match loudness", isOn: $player.matchLoudness)
                .toggleStyle(.checkbox)
                .font(.callout)
                .lineLimit(1)
                .help("Play both versions at the same loudness, so you compare cleanliness rather than volume")
            HStack(spacing: 2) {
                Button { store.selectNext(-1) } label: { Image(systemName: "chevron.up").frame(width: 26, height: 26) }
                    .help("Previous clip (↑)")
                Button { store.selectNext(1) } label: { Image(systemName: "chevron.down").frame(width: 26, height: 26) }
                    .help("Next clip (↓)")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .motion(Motion.quick, value: clip.status == .working)
    }
}

struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
    }
}

/// Large two-way switch between the original and cleaned sound. Used constantly, so it moves fast and plainly.
struct ABSwitch: View {
    @Binding var cleaned: Bool
    private let segment: CGFloat = 112

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08))
            Capsule()
                .fill(cleaned ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: segment - 4)
                .offset(x: cleaned ? segment + 2 : 2)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            HStack(spacing: 0) {
                label("Original", active: !cleaned) { cleaned = false }
                label("Cleaned", active: cleaned) { cleaned = true }
            }
        }
        .frame(width: segment * 2, height: 32)
        .motion(Motion.quick, value: cleaned)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listen to")
        .accessibilityValue(cleaned ? "Cleaned" : "Original")
        .accessibilityAdjustableAction { _ in cleaned.toggle() }
    }

    private func label(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(active ? .white : .secondary)
                .frame(width: segment, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ResultsStrip: View {
    @ObservedObject var clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let p = clip.preview {
                    let quieter = p.analysis.noiseFloorDb - p.stats.noiseFloorDb
                    ResultTile(icon: "waveform.path.ecg", title: "Background noise",
                               value: "\(fmt(p.analysis.noiseFloorDb)) → \(fmt(p.stats.noiseFloorDb)) dB",
                               note: quieter >= 1 ? "\(Int(quieter.rounded())) dB quieter" : "unchanged", good: quieter >= 6)
                    ResultTile(icon: "person.wave.2", title: "Speech quality", value: quality(p),
                               note: "DNSMOS score, out of 5", good: qualityGain(p) > 0.05)
                    ResultTile(icon: "speaker.wave.2", title: "Loudness",
                               value: "\(fmt(p.analysis.lufs)) → \(fmt(p.stats.lufs)) LUFS",
                               note: p.stats.littleSpeech ? "left unchanged" : "peaks ≤ \(fmt(p.stats.truePeakDb)) dB", good: nil)
                    ResultTile(icon: "cpu", title: "Model", value: shortModel(p.stats.model),
                               note: p.stats.auto != nil ? "chosen automatically" : "chosen by you",
                               good: nil)
                } else {
                    ForEach(0..<4, id: \.self) { _ in ResultTile.placeholder }
                }
            }
            if let w = clip.preview?.stats.warnings, !w.isEmpty {
                ForEach(w, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            if let e = clip.error, clip.preview != nil {
                Label(e, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quality(_ p: PreviewResult) -> String {
        guard let a = clip.lastAuto, let o = a.scores["original"] else { return "–" }
        let c = a.scores[p.stats.model]
        return String(format: "%.2f", o.ovrl) + " → " + (c.map { String(format: "%.2f", $0.ovrl) } ?? "–")
    }

    private func qualityGain(_ p: PreviewResult) -> Double {
        guard let a = clip.lastAuto, let o = a.scores["original"], let c = a.scores[p.stats.model] else { return 0 }
        return c.ovrl - o.ovrl
    }
}

struct ResultTile: View {
    let icon: String
    let title: String
    let value: String
    let note: String
    let good: Bool?

    static var placeholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)).frame(height: 66)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13.5, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
                .contentTransition(.numericText())
            Text(note).font(.caption2).foregroundStyle(good == true ? Color.green : Color.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .motion(Motion.quick, value: value)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 92, height: 92)
                Image(systemName: "waveform.badge.plus").font(.system(size: 38, weight: .medium)).foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 6) {
                Text("Drop your film's clips here").font(.title2.weight(.semibold))
                Text("A whole folder works: CleanVoice finds every video and audio file inside it.")
                    .foregroundStyle(.secondary)
            }
            Button { chooseMedia(store) } label: { Text("Choose Folder or Clips…").padding(.horizontal, 8) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            HStack(alignment: .top, spacing: 26) {
                HowStep(icon: "1.circle.fill", title: "Add", text: "Drop a folder of clips")
                HowStep(icon: "2.circle.fill", title: "Review", text: "Hum and noise are removed automatically. Compare and adjust.")
                HowStep(icon: "3.circle.fill", title: "Export", text: "One click into simple folders for DaVinci")
            }
            .padding(.top, 12)
            Label("Use source clips, not a finished mix: music and sound effects would be removed too. Your originals are never changed.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .padding(20)
        )
    }
}

struct HowStep: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor)
            Text(title).font(.callout.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(width: 150)
    }
}

struct EngineStatusBar: View {
    @EnvironmentObject var engine: EngineClient

    var body: some View {
        switch engine.state {
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading cleaning models…").font(.callout)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6).background(.bar)
        case .failed(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).font(.callout).lineLimit(2)
                Spacer()
                Button("Retry") { engine.restart() }
            }
            .padding(.horizontal, 14).padding(.vertical, 6).background(Color.orange.opacity(0.12))
        default:
            EmptyView()
        }
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            Text(text).font(.callout).lineLimit(2)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 22, height: 22) }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            dismiss()
        }
    }
}

// MARK: - Controls (inspector)

struct ControlsView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var engine: EngineClient
    @StateObject private var showAdvanced = Box(false)
    @StateObject private var showClaude = Box(false)

    private func bind<T>(_ kp: WritableKeyPath<CleanSettings, T>) -> Binding<T> {
        Binding(get: { store.editing[keyPath: kp] }, set: { v in var s = store.editing; s[keyPath: kp] = v; store.editing = s })
    }

    var body: some View {
        let s = store.editing
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.selected != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Apply changes to", selection: Binding(get: { store.clipOnly }, set: { store.clipOnly = $0 })) {
                            Text("All clips").tag(false)
                            Text("This clip only").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(store.clipOnly ? "Only this clip changes. Switch back to “All clips” to follow the project settings again."
                                            : "Changes apply to every clip that doesn’t have its own settings.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card(title: "Strength") {
                    PresetRow(settings: s) { preset in
                        var n = store.editing
                        n.noiseReduction = preset.noise
                        n.full = preset.full
                        store.editing = n
                    }
                    NoiseSlider(settings: s, set: { v, full in
                        var n = store.editing
                        n.full = full
                        if !full { n.noiseReduction = v }
                        store.editing = n
                    })
                }

                Card(title: "Voice") {
                    SliderRow(title: "Clarity", value: bind(\.clarity), range: CleanSettings.clarityRange, step: 0.5,
                              display: clarityWords(s.clarity), detail: "\(signed(s.clarity)) dB at 3.5 kHz")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Loudness").font(.callout)
                        Picker("Loudness", selection: Binding(get: { loudnessTag(s) }, set: { setLoudness($0) })) {
                            Text("Cinema −24").tag("cinema")
                            Text("Web −16").tag("web")
                            Text("Keep").tag("keep")
                            if loudnessTag(s) == "custom" { Text("\(fmt(s.loudness))").tag("custom") }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                DisclosureGroup(isExpanded: $showAdvanced.value) {
                    AdvancedControls(bind: bind)
                        .padding(.top, 8)
                } label: {
                    Text("Advanced").font(.headline)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(Motion.enter) { showAdvanced.value.toggle() } }
                }

                DisclosureGroup(isExpanded: $showClaude.value) {
                    ClaudePanel().padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                        Text("Ask Claude to adjust")
                    }
                    .font(.headline)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(Motion.enter) { showClaude.value.toggle() } }
                }
            }
            .padding(16)
        }
    }

    private func loudnessTag(_ s: CleanSettings) -> String {
        if !s.loudnessOn { return "keep" }
        if abs(s.loudness + 24) < 0.01 { return "cinema" }
        if abs(s.loudness + 16) < 0.01 { return "web" }
        return "custom"
    }

    private func setLoudness(_ tag: String) {
        var n = store.editing
        switch tag {
        case "cinema": n.loudnessOn = true; n.loudness = -24
        case "web": n.loudnessOn = true; n.loudness = -16
        case "keep": n.loudnessOn = false
        default: return
        }
        store.editing = n
    }

    private func clarityWords(_ v: Double) -> String {
        v < -0.9 ? "Softer" : v < 1.5 ? "Natural" : v < 3.5 ? "Clearer" : "Crisp"
    }
}

func signed(_ v: Double) -> String { (v > 0 ? "+" : "") + fmt(v) }

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct Preset: Identifiable {
    let id: String
    let title: String
    let caption: String
    let noise: Double
    let full: Bool
    static let all = [
        Preset(id: "gentle", title: "Gentle", caption: "Keeps more room sound", noise: 16, full: false),
        Preset(id: "balanced", title: "Balanced", caption: "Faint room tone", noise: 28, full: false),
        Preset(id: "maximum", title: "Maximum", caption: "Silent gaps", noise: 28, full: true),
    ]
    func matches(_ s: CleanSettings) -> Bool { full ? s.full : (!s.full && abs(s.noiseReduction - noise) < 0.5) }
}

struct PresetRow: View {
    let settings: CleanSettings
    let choose: (Preset) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Preset.all) { p in
                PresetCard(preset: p, selected: p.matches(settings), recommended: p.id == "balanced") { choose(p) }
            }
        }
    }
}

struct PresetCard: View {
    let preset: Preset
    let selected: Bool
    let recommended: Bool
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(preset.title).font(.system(size: 12.5, weight: .semibold))
                    if recommended {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow).help("Recommended")
                    }
                }
                Text(preset.caption).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hover.value ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
        .motion(Motion.quick, value: selected)
        .motion(Motion.quick, value: hover.value)
        .accessibilityLabel("\(preset.title): \(preset.caption)\(recommended ? ", recommended" : "")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// One control for background removal: 0–60 dB, with the far end meaning "remove everything".
struct NoiseSlider: View {
    let settings: CleanSettings
    let set: (Double, Bool) -> Void
    private let fullStop = 66.0

    var body: some View {
        let value = settings.full ? fullStop : settings.noiseReduction
        SliderRow(title: "Noise removal",
                  value: Binding(get: { value }, set: { v in v >= 63 ? set(60, true) : set(v.rounded(), false) }),
                  range: 0...fullStop, step: 1,
                  display: words(value), detail: settings.full ? "All background removed" : "\(Int(value)) dB of background removed")
    }

    private func words(_ v: Double) -> String {
        v >= 63 ? "Maximum" : v < 10 ? "Light" : v < 22 ? "Gentle" : v < 34 ? "Balanced" : "Strong"
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout)
                Spacer()
                Text(display).font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
                    .contentTransition(.opacity)
            }
            Slider(value: $value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(detail ?? display)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct AdvancedControls: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var engine: EngineClient
    let bind: (WritableKeyPath<CleanSettings, String>) -> Binding<String>
    init(bind: @escaping (WritableKeyPath<CleanSettings, String>) -> Binding<String>) { self.bind = bind }

    private func num(_ kp: WritableKeyPath<CleanSettings, Double>) -> Binding<Double> {
        Binding(get: { store.editing[keyPath: kp] }, set: { v in var s = store.editing; s[keyPath: kp] = v; store.editing = s })
    }

    var body: some View {
        let s = store.editing
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cleaning model").font(.callout)
                Picker("Cleaning model", selection: bind(\.model)) {
                    Text("Auto: try all, keep the best (recommended)").tag("auto")
                    Divider()
                    ForEach(engine.models) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                if let a = store.selected?.lastAuto {
                    Text(autoSummary(a)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Mains hum").font(.callout)
                Picker("Mains hum", selection: bind(\.hum)) {
                    Text("Auto").tag("auto"); Text("50 Hz").tag("50"); Text("60 Hz").tag("60"); Text("Off").tag("off")
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            SliderRow(title: "Low cut (rumble, wind)", value: num(\.lowCut), range: CleanSettings.lowCutRange, step: 5,
                      display: s.lowCut < 1 ? "Off" : "\(Int(s.lowCut)) Hz")
            SliderRow(title: "Warmth", value: num(\.warmth), range: CleanSettings.warmthRange, step: 0.5,
                      display: "\(signed(s.warmth)) dB", detail: "Body of the voice around 250 Hz")
            SliderRow(title: "Evenness", value: num(\.evenness), range: 0...1, step: 0.05,
                      display: s.evenness < 0.01 ? "Off" : s.evenness < 0.35 ? "Light" : s.evenness < 0.7 ? "Medium" : "Strong",
                      detail: "Smooths loud and quiet words")
            SliderRow(title: "Exact loudness", value: num(\.loudness), range: CleanSettings.loudnessRange, step: 0.5,
                      display: s.loudnessOn ? "\(fmt(s.loudness)) LUFS" : "Kept")
                .disabled(!s.loudnessOn)
            HStack {
                Button("Reset to Defaults") { store.resetToDefaults() }
                Spacer()
                Menu("Defaults") {
                    Button("Save Current Settings as My Defaults") { store.saveAsDefaults() }
                    Button("Restore Original Defaults") { store.resetDefaultsToFactory() }
                }
                .fixedSize()
            }
        }
    }

    private func autoSummary(_ a: AutoInfo) -> String {
        let parts = ["deepfilternet3", "deepfilternet2", "rnnoise", "spectral"].compactMap { m in
            a.scores[m].map { "\(shortModel(m)) \(String(format: "%.2f", $0.ovrl))" }
        }
        let orig = a.scores["original"].map { String(format: "%.2f", $0.ovrl) } ?? "–"
        return "Auto picked \(shortModel(a.model)) for this clip. Quality scores (out of 5, on the \(a.scoredOn)): original \(orig); " + parts.joined(separator: ", ") + "."
    }
}

// MARK: - Export sheet

struct ExportSheet: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var drawn = Box(false)

    var body: some View {
        let o = store.exportOptions
        let total = store.clips.count
        let folder = store.clips.first.map { store.outputFolder(for: $0) }
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up.on.square.fill").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export for DaVinci Resolve").font(.title2.weight(.semibold))
                    Text("\(total) clip\(total == 1 ? "" : "s"), \(store.preparedCount) already cleaned. Any others are cleaned during export.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let done = store.lastExport, !store.isExporting {
                ExportDone(done: done, drawn: drawn.value)
                    .onAppear {
                        drawn.value = false
                        withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.4).delay(0.05)) { drawn.value = true }
                    }
            } else {
                Card(title: "Save to") {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        Text(folder?.path ?? "–").font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Change…") { chooseFolder() }
                        if store.outputDir != nil { Button("Default") { store.outputDir = nil } }
                    }
                }
                Card(title: "Include") {
                    Toggle(isOn: Binding(get: { o.video }, set: { store.exportOptions.video = $0 })) {
                        OptionText(title: "Videos with the clean audio", text: "Drop straight into DaVinci. Same picture, same timecode.")
                    }
                    Toggle(isOn: Binding(get: { o.audio }, set: { store.exportOptions.audio = $0 })) {
                        OptionText(title: "Clean audio files (WAV, 24-bit)", text: "For Fairlight, or syncing against your edit.")
                    }
                }
                Card(title: "Organise") {
                    Picker("Folders", selection: Binding(get: { o.flat }, set: { store.exportOptions.flat = $0 })) {
                        Text("Keep my folder structure").tag(false)
                        Text("Everything in one folder").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Toggle(isOn: Binding(get: { o.sameNames }, set: { store.exportOptions.sameNames = $0 })) {
                        OptionText(title: "Keep original file names (recommended)",
                                   text: "DaVinci can then swap your edit over to the cleaned files in one step.")
                    }
                    Text(example(o)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle)
                }
                if let p = store.exportProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            .motion(Motion.quick, value: p.done)
                        Text("Exporting \(store.exportCurrent ?? "")  ·  \(p.done) of \(p.total)")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .transition(.opacity)
                }
            }

            HStack {
                if store.lastExport != nil, !store.isExporting {
                    Button("Export Again") { store.resetLastExport() }
                }
                Spacer()
                Button(store.lastExport != nil && !store.isExporting ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isExporting)
                if store.lastExport == nil || store.isExporting {
                    Button {
                        Task { await store.export(store.clips) }
                    } label: {
                        Text(store.isExporting ? "Exporting…" : "Export \(total) Clip\(total == 1 ? "" : "s")").frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isExporting || total == 0 || (!o.video && !o.audio))
                }
            }
        }
        .padding(24)
        .frame(width: 580)
        .motion(Motion.enter, value: store.exportProgress == nil)
        .motion(Motion.enter, value: store.lastExport == nil)
    }

    private func example(_ o: ExportOptions) -> String {
        guard let c = store.clips.first(where: { $0.relativePath.contains("/") }) ?? store.clips.first else { return "" }
        let rel = c.relativePath
        let dir = (rel as NSString).deletingLastPathComponent
        var stem = (c.url.lastPathComponent as NSString).deletingPathExtension
        if o.flat, !dir.isEmpty { stem = dir.replacingOccurrences(of: "/", with: " - ") + " - " + stem }
        if !o.sameNames { stem += "_clean" }
        let sub = o.flat || dir.isEmpty ? "" : dir + "/"
        let ext = c.url.pathExtension.lowercased()
        let vext = ["mp4", "m4v"].contains(ext) ? "mp4" : "mov"
        var lines: [String] = []
        let base = ProjectStore.exportFolderName
        if o.video, c.isVideoGuess { lines.append("\(base)/Video/\(sub)\(stem).\(vext)") }
        if o.audio || !c.isVideoGuess { lines.append("\(base)/Audio/\(sub)\(stem).wav") }
        return "e.g.  " + lines.joined(separator: "\n       ")
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Export Here"
        if p.runModal() == .OK { store.outputDir = p.url }
    }
}

struct OptionText: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ExportDone: View {
    let done: (count: Int, failed: Int, folder: URL)
    let drawn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(done.failed == 0 ? Color.green : Color.orange).frame(width: 46, height: 46)
                    CheckShape().trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 20, height: 16)
                }
                .scaleEffect(drawn ? 1 : 0.85)
                VStack(alignment: .leading, spacing: 2) {
                    Text(done.failed == 0 ? "All \(done.count) clips exported" : "\(done.count - done.failed) of \(done.count) clips exported")
                        .font(.title3.weight(.semibold))
                    if done.failed > 0 {
                        Text("\(done.failed) had a problem; they're marked in the clip list.").font(.callout).foregroundStyle(.orange)
                    }
                    Text(done.folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([done.folder]) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .controlSize(.large)
            Card(title: "In DaVinci Resolve") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("New edit: drag the **Video** folder into the Media Pool.", systemImage: "1.circle")
                    Label("Already edited with the originals: in the Media Pool, select the clips, right-click › **Change Source Folder…**, and point it from your original folder to the **Video** folder. Names and timecode match, so the edit picks up the clean audio.",
                          systemImage: "2.circle")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }
}

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

// MARK: - Claude panel

struct ClaudePanel: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var claude: ClaudeAssistant
    @StateObject private var text = Box("")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if claude.messages.isEmpty {
                Text("Describe what you hear, like “voice sounds muffled” or “a bit robotic”. Claude moves the sliders and you can undo. Optional: uses your Claude login, about 1–2k tokens per request. Nothing else in CleanVoice uses tokens.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(claude.messages.suffix(6)) { m in
                Text(m.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bubble(m.role), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack {
                TextField("Ask for a change…", text: $text.value, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                    .disabled(claude.busy)
                if claude.busy {
                    ProgressView().controlSize(.small)
                    Button("Stop") { claude.cancel() }
                } else {
                    Button("Send", action: send).disabled(text.value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack {
                if let u = store.undoSnapshot {
                    Button("Undo \(u.label)") { store.undoLastChange() }
                }
                Spacer()
                Picker("Model", selection: $claude.model) {
                    Text("Haiku (cheapest)").tag("haiku")
                    Text("Sonnet").tag("sonnet")
                }
                .labelsHidden()
                .fixedSize()
                .help("Claude model used for requests")
            }
            if claude.cliPath == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code isn’t installed. Run this once in Terminal, then sign in with `claude`:").font(.caption).foregroundStyle(.orange)
                    HStack {
                        Text(ClaudeAssistant.installCommand).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ClaudeAssistant.installCommand, forType: .string)
                        }
                        Button("Retry") { claude.locate() }
                    }
                }
            }
        }
        .motion(Motion.enter, value: claude.messages.count)
    }

    private func bubble(_ r: ChatMessage.Role) -> Color {
        switch r {
        case .user: return Color.accentColor.opacity(0.12)
        case .claude: return Color.secondary.opacity(0.1)
        case .error: return Color.orange.opacity(0.15)
        }
    }

    private func send() {
        let t = text.value
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty, !claude.busy else { return }
        text.value = ""
        Task {
            if let r = await claude.ask(t, settings: store.editing, clipOnly: store.clipOnly, clip: store.selected) {
                store.applyChanges(r.changes, scope: r.scope, label: "Claude’s change")
            }
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var engine: EngineClient
    @EnvironmentObject var claude: ClaudeAssistant
    @StateObject private var enginePath = Box(Defaults.engineDir.path)
    @StateObject private var claudePath = Box(Defaults.claudePath)

    var body: some View {
        Form {
            Section("Cleaning engine") {
                TextField("Engine folder", text: $enginePath.value)
                HStack {
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { enginePath.value = u.path }
                    }
                    Button("Apply and Restart Engine") {
                        Defaults.engineDir = URL(fileURLWithPath: enginePath.value)
                        engine.restart()
                    }
                }
            }
            Section("Claude (optional)") {
                TextField("Claude Code path (blank = find automatically)", text: $claudePath.value)
                HStack {
                    Button("Apply") { Defaults.claudePath = claudePath.value; claude.locate() }
                    Text(claude.cliPath ?? "Not found").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
