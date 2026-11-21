import Foundation

/// Cleaning settings, mirrored 1:1 with the engine's settings (snake_case on the wire).
struct CleanSettings: Codable, Equatable {
    var model: String = "auto"
    var noiseReduction: Double = 28
    var full: Bool = false
    var hum: String = "auto"
    var lowCut: Double = 80
    var warmth: Double = -2
    var clarity: Double = 2
    var evenness: Double = 0.5
    var loudness: Double = -24
    var loudnessOn: Bool = true
    var truePeak: Double = -1.5

    static let factory = CleanSettings()

    init() {}

    // Tolerant decoding so saved projects survive new settings being added later.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CleanSettings()
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? d.noiseReduction
        full = try c.decodeIfPresent(Bool.self, forKey: .full) ?? d.full
        hum = try c.decodeIfPresent(String.self, forKey: .hum) ?? d.hum
        lowCut = try c.decodeIfPresent(Double.self, forKey: .lowCut) ?? d.lowCut
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? d.warmth
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? d.clarity
        evenness = try c.decodeIfPresent(Double.self, forKey: .evenness) ?? d.evenness
        loudness = try c.decodeIfPresent(Double.self, forKey: .loudness) ?? d.loudness
        loudnessOn = try c.decodeIfPresent(Bool.self, forKey: .loudnessOn) ?? d.loudnessOn
        truePeak = try c.decodeIfPresent(Double.self, forKey: .truePeak) ?? d.truePeak
    }

    /// The dictionary sent to the engine.
    var engineJSON: [String: Any] {
        [
            "model": model, "noise_reduction": noiseReduction, "full": full, "hum": hum,
            "low_cut": lowCut, "warmth": warmth, "clarity": clarity, "evenness": evenness,
            "loudness": loudnessOn ? loudness as Any : NSNull(), "true_peak": truePeak,
        ]
    }

    /// Apply engine-style changes (e.g. from Claude), clamped to the valid ranges. Unknown keys are ignored.
    func applying(_ changes: [String: Any]) -> CleanSettings {
        var s = self
        func num(_ k: String) -> Double? { (changes[k] as? NSNumber)?.doubleValue ?? (changes[k] as? String).flatMap(Double.init) }
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, v)) }
        if let m = changes["model"] as? String, Self.modelIDs.contains(m) { s.model = m }
        if let v = num("noise_reduction") { s.noiseReduction = clamp(v, Self.noiseRange) }
        if let v = changes["full"] as? Bool { s.full = v }
        if let v = changes["hum"] { let h = "\(v)".lowercased(); if ["auto", "50", "60", "off"].contains(h) { s.hum = h } }
        if let v = num("low_cut") { s.lowCut = clamp(v, Self.lowCutRange) }
        if let v = num("warmth") { s.warmth = clamp(v, Self.warmthRange) }
        if let v = num("clarity") { s.clarity = clamp(v, Self.clarityRange) }
        if let v = num("evenness") { s.evenness = clamp(v, 0...1) }
        if changes.keys.contains("loudness") {
            if let v = num("loudness") { s.loudness = clamp(v, Self.loudnessRange); s.loudnessOn = true } else { s.loudnessOn = false }
        }
        if let v = num("true_peak") { s.truePeak = clamp(v, -6...0) }
        return s
    }

    static let modelIDs = ["auto", "deepfilternet3", "deepfilternet2", "rnnoise", "spectral"]
    static let noiseRange: ClosedRange<Double> = 0...60
    static let lowCutRange: ClosedRange<Double> = 0...200
    static let warmthRange: ClosedRange<Double> = -6...3
    static let clarityRange: ClosedRange<Double> = -3...6
    static let loudnessRange: ClosedRange<Double> = -31...(-12)
}

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let label: String
    static let fallback: [ModelInfo] = [
        ModelInfo(id: "deepfilternet3", label: "DeepFilterNet 3 (AI, strongest)"),
        ModelInfo(id: "deepfilternet2", label: "DeepFilterNet 2 (AI, alternative)"),
        ModelInfo(id: "rnnoise", label: "RNNoise (light AI)"),
        ModelInfo(id: "spectral", label: "Spectral (classic, most natural, keeps non-voice sounds)"),
    ]
}

/// User-editable defaults, stored in the app's preferences.
enum Defaults {
    private static let key = "defaultSettings"
    static var settings: CleanSettings {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let s = try? JSONDecoder().decode(CleanSettings.self, from: d) else { return .factory }
            return s
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
    static func resetToFactory() { UserDefaults.standard.removeObject(forKey: key) }

    static var engineDir: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "engineDir"), !p.isEmpty { return URL(fileURLWithPath: p) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Tools/cleanvoice/engine")
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "engineDir") }
    }
    static var wavStem: Bool {
        get { UserDefaults.standard.object(forKey: "wavStem") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wavStem") }
    }
    static var claudePath: String {
        get { UserDefaults.standard.string(forKey: "claudePath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "claudePath") }
    }
}
