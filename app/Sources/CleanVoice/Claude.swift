import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, claude, error }
    let id = UUID()
    let role: Role
    let text: String
}

/// Optional helper: turns a plain-English request into setting changes using the Claude Code CLI and your Claude login.
/// Only used when you send a message; nothing else in the app needs it.
@MainActor
final class ClaudeAssistant: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published private(set) var busy = false
    @Published private(set) var cliPath: String?
    @Published var model: String = UserDefaults.standard.string(forKey: "claudeModel") ?? "haiku" {
        didSet { UserDefaults.standard.set(model, forKey: "claudeModel") }
    }
    private var running: Process?

    init() { locate() }

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    private var signInHelp: String {
        let bundled = cliPath?.contains("Application Support/Claude/claude-code") == true
        return bundled
            ? "Claude Code needs a one-time setup. In Terminal, run:\n\(Self.installCommand)\nthen run `claude` and sign in. Then press Send again."
            : "Claude Code isn't signed in. Run `claude` once in Terminal to sign in, then press Send again."
    }

    func locate() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [Defaults.claudePath, "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        // Fallback: the copy bundled with the Claude desktop app (newest version).
        let bundled = "\(home)/Library/Application Support/Claude/claude-code"
        if let versions = try? fm.contentsOfDirectory(atPath: bundled) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                for h in (try? fm.contentsOfDirectory(atPath: "\(bundled)/\(v)")) ?? [] {
                    candidates.append("\(bundled)/\(v)/\(h)/claude.app/Contents/MacOS/claude")
                }
            }
        }
        cliPath = candidates.first { !$0.isEmpty && fm.isExecutableFile(atPath: $0) }
    }

    func cancel() {
        running?.terminate()
    }

    /// Ask Claude for setting changes. Returns the changes and the scope ("all" or "clip"), or nil on failure.
    func ask(_ request: String, settings: CleanSettings, clipOnly: Bool, clip: Clip?) async -> (changes: [String: Any], scope: String)? {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return nil }
        messages.append(ChatMessage(role: .user, text: text))
        guard let cli = cliPath else {
            messages.append(ChatMessage(role: .error, text: "Claude Code isn't installed. In Terminal, run:\n\(Self.installCommand)\nthen run `claude` once to sign in, and press Retry."))
            return nil
        }
        busy = true
        defer { busy = false }
        let prompt = buildPrompt(text, settings: settings, clipOnly: clipOnly, clip: clip)
        let result: (out: String, err: String, code: Int32)
        do {
            result = try await run(cli, args: [
                "-p", prompt, "--output-format", "json", "--model", model,
                "--system-prompt", Self.systemPrompt, "--tools", "", "--strict-mcp-config",
                "--disable-slash-commands", "--no-session-persistence",
            ])
        } catch {
            messages.append(ChatMessage(role: .error, text: "Couldn't run Claude Code: \(error.localizedDescription)"))
            return nil
        }
        locate()  // pick up a CLI installed since launch
        // The CLI prints one JSON object: {"type":"result","result":"...","is_error":false,...}
        guard let envelope = Self.firstJSONObject(in: result.out) else {
            let hint = (result.err + result.out).lowercased().contains("login") || (result.err + result.out).lowercased().contains("auth")
                ? signInHelp
                : "Claude Code returned an error (code \(result.code)). \(result.err.suffix(300))"
            messages.append(ChatMessage(role: .error, text: hint))
            return nil
        }
        let reply = envelope["result"] as? String ?? ""
        if envelope["is_error"] as? Bool == true {
            let lower = reply.lowercased()
            messages.append(ChatMessage(role: .error, text: lower.contains("login") || lower.contains("auth") || lower.contains("api key")
                ? signInHelp
                : "Claude: \(reply.prefix(300))"))
            return nil
        }
        guard let answer = Self.firstJSONObject(in: reply) else {
            messages.append(ChatMessage(role: .claude, text: reply.isEmpty ? "No changes suggested." : String(reply.prefix(400))))
            return nil
        }
        let changes = answer["changes"] as? [String: Any] ?? [:]
        let explanation = answer["explanation"] as? String ?? ""
        let scope = (answer["scope"] as? String) == "clip" || clipOnly ? "clip" : "all"
        let summary = changes.isEmpty ? "No changes needed." : changes.keys.sorted().map { "\($0) → \(Self.describe(changes[$0]))" }.joined(separator: ", ")
        messages.append(ChatMessage(role: .claude, text: explanation.isEmpty ? summary : "\(explanation)\n\(summary)"))
        return changes.isEmpty ? nil : (changes, scope)
    }

    private static func describe(_ v: Any?) -> String {
        switch v {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n.boolValue ? "on" : "off"
        case let n as NSNumber: return String(format: "%g", n.doubleValue)
        case let s as String: return s
        case is NSNull, nil: return "off"
        default: return "\(v!)"
        }
    }

    private func buildPrompt(_ text: String, settings: CleanSettings, clipOnly: Bool, clip: Clip?) -> String {
        var ctx: [String: Any] = ["current_settings": settings.engineJSON, "editing": clipOnly ? "this clip only" : "all clips"]
        if let p = clip?.preview {
            let a = p.analysis, s = p.stats
            var m: [String: Any] = [
                "file": clip?.url.lastPathComponent ?? "", "duration_s": a.duration, "hum_found_hz": a.humBase as Any,
                "background_before_db": a.noiseFloorDb, "background_after_db": s.noiseFloorDb,
                "loudness_before_lufs": a.lufs, "loudness_after_lufs": s.lufs, "model_used": s.model,
                "channels_differ": !a.linkedChannels, "warnings": s.warnings,
            ]
            if let auto = s.auto {
                m["quality_scores_dnsmos_1to5"] = auto.scores.mapValues { ["voice": $0.sig, "background": $0.bak, "overall": $0.ovrl] }
            }
            ctx["clip_measurements"] = m
        }
        let json = (try? JSONSerialization.data(withJSONObject: ctx, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "\(json)\n\nRequest: \(text)"
    }

    static let systemPrompt = """
    You tune a film dialogue-cleaning tool. You cannot hear the audio: decide from the user's description and the measurements. \
    Reply with ONLY one JSON object, no prose outside it: {"changes": {...}, "scope": "all" or "clip", "explanation": "one short sentence"}. \
    Include only settings that should change; use {} if nothing should. Use scope "clip" only if the user means this clip alone. Settings:
    model: "auto" (tries all, keeps best DNSMOS score) | "deepfilternet3" (strongest AI) | "deepfilternet2" (AI, often slightly cleaner) | "rnnoise" (light AI) | "spectral" (classic; most natural, keeps footsteps/doors/ambience, least removal)
    noise_reduction: 0-60 dB of background removed (default 28 keeps faint room tone); full: true removes all background
    hum: "auto" | "50" | "60" | "off" (mains hum notch filters); low_cut: 0-200 Hz high-pass (rumble, wind, handling)
    warmth: -6..3 dB at 250 Hz (body; lower if boomy/muddy, raise if thin); clarity: -3..6 dB at 3.5 kHz (presence; raise if muffled, lower if harsh/sibilant)
    evenness: 0-1 compression (higher = more even level); loudness: -31..-12 LUFS target, or null to keep level (cinema -24, web -16); true_peak: -6..0 dBTP
    Hints: robotic/watery/underwater/swirly voice = over-processing: lower noise_reduction (e.g. 15-20), set full false, or try spectral/deepfilternet3. \
    Still noisy: raise noise_reduction or full true. Hum audible: hum "50" or "60". Background sounds missing that should stay: model spectral or lower noise_reduction.
    """

    private func run(_ path: String, args: [String]) async throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.temporaryDirectory  // no project files or instructions get picked up
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        running = p
        defer { running = nil }
        try p.run()
        // Drain both pipes concurrently so a large reply can never block the child on a full pipe buffer.
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let group = DispatchGroup()
                var o = Data(), e = Data()
                group.enter()
                DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                e = err.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: (String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self), p.terminationStatus))
            }
        }
    }

    /// Finds the first balanced {...} JSON object in text (Claude may wrap it in prose or code fences).
    static func firstJSONObject(in text: String) -> [String: Any]? {
        let chars = Array(text.utf8)
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { inString = false }
                continue
            }
            if c == UInt8(ascii: "\"") { inString = true }
            else if c == UInt8(ascii: "{") { if depth == 0 { start = i }; depth += 1 }
            else if c == UInt8(ascii: "}"), depth > 0 {
                depth -= 1
                if depth == 0, let s = start {
                    let slice = Data(chars[s...i])
                    if let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] { return obj }
                    start = nil
                }
            }
        }
        return nil
    }
}
