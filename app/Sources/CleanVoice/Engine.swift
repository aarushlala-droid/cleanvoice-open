import Foundation

// MARK: - Engine results (decoded from the worker's snake_case JSON)

struct Analysis: Codable, Equatable {
    let key: String
    let duration: Double
    let channels: Int
    let hasVideo: Bool
    let linkedChannels: Bool
    let humBase: Int?
    let humHarmonics: [Int]
    let noiseFloorDb: Double
    let voiceDb: Double
    let peakDb: Double
    let lufs: Double
}

struct QualityScore: Codable, Equatable {
    let sig: Double
    let bak: Double
    let ovrl: Double
}

struct AutoInfo: Codable, Equatable {
    let model: String
    let scores: [String: QualityScore]
    let errors: [String: String]
    let scoredOn: String
}

struct RenderStats: Codable, Equatable {
    let lufs: Double
    let truePeakDb: Double
    let noiseFloorDb: Double
    let voiceDb: Double
    let speechRatio: Double
    let littleSpeech: Bool
    let model: String
    let modelLabel: String
    let auto: AutoInfo?
    let warnings: [String]
}

struct PreviewResult: Codable, Equatable {
    let wav: String
    let settingsHash: String
    let stats: RenderStats
    let analysis: Analysis
    let originalWav: String?
}

struct ExportResult: Codable {
    let outputs: [String]
    let stats: RenderStats
    let analysis: Analysis
    let outDir: String
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func decodeEngine<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: object)
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(T.self, from: data)
}

// MARK: - Worker process client

enum EngineState: Equatable {
    case stopped, starting, ready
    case failed(String)
}

/// Runs `cleanvoice.py serve` once and exchanges JSON lines with it. The worker handles one request at a time.
@MainActor
final class EngineClient: ObservableObject {
    @Published private(set) var state: EngineState = .stopped
    @Published private(set) var models: [ModelInfo] = ModelInfo.fallback

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (cont: CheckedContinuation<[String: Any], Error>, progress: (@MainActor (Double) -> Void)?)] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var stderrTail = ""

    func start() {
        guard process == nil else { return }
        let dir = Defaults.engineDir
        let python = dir.appendingPathComponent(".venv/bin/python")
        let script = dir.appendingPathComponent("cleanvoice.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else {
            fail("Cleaning engine not found in \(dir.path). Check the engine folder in Settings (⌘,).")
            return
        }
        let p = Process()
        p.executableURL = python
        p.arguments = ["-I", script.path, "serve"]
        p.currentDirectoryURL = dir
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            FileHandle.standardError.write(data)
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stderrTail = String(((self?.stderrTail ?? "") + text).suffix(600)) } }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminated(proc, code: code) } }
        }
        do {
            try p.run()
        } catch {
            fail("Could not start the cleaning engine: \(error.localizedDescription)")
            return
        }
        process = p
        input = inPipe.fileHandleForWriting
        state = .starting
    }

    func restart() {
        let old = process
        process = nil
        input = nil
        buffer.removeAll()
        failPending("The cleaning engine was restarted.")
        state = .stopped
        old?.terminate()
        start()
    }

    func stop() {
        guard let p = process else { return }
        if let data = try? JSONSerialization.data(withJSONObject: ["id": 0, "cmd": "shutdown"]) {
            try? input?.write(contentsOf: data + Data("\n".utf8))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
    }

    private func waitUntilReady() async throws {
        switch state {
        case .ready: return
        case .stopped, .failed: start()
        case .starting: break
        }
        if case .failed(let msg) = state { throw EngineError(message: msg) }
        if state == .ready { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in readyWaiters.append(c) }
    }

    /// Send one command and wait for its reply. `progress` receives 0...1 updates on the main actor.
    func request(_ cmd: String, _ params: [String: Any] = [:], progress: (@MainActor (Double) -> Void)? = nil) async throws -> [String: Any] {
        try await waitUntilReady()
        let id = nextID
        nextID += 1
        var msg = params
        msg["id"] = id
        msg["cmd"] = cmd
        let data = try JSONSerialization.data(withJSONObject: msg) + Data("\n".utf8)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = (cont, progress)
            do {
                try input?.write(contentsOf: data)
            } catch {
                pending[id] = nil
                cont.resume(throwing: EngineError(message: "The cleaning engine is not responding."))
            }
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ msg: [String: Any]) {
        if let event = msg["event"] as? String {
            switch event {
            case "ready":
                state = .ready
                readyWaiters.forEach { $0.resume() }
                readyWaiters.removeAll()
                Task { await loadModels() }
            case "progress":
                if let id = msg["id"] as? Int, let v = msg["value"] as? Double { pending[id]?.progress?(v) }
            case "error":
                FileHandle.standardError.write(Data("engine: \(msg["error"] ?? "")\n".utf8))
            default: break
            }
            return
        }
        guard let id = msg["id"] as? Int, let entry = pending.removeValue(forKey: id) else { return }
        if msg["ok"] as? Bool == true {
            entry.cont.resume(returning: msg["result"] as? [String: Any] ?? [:])
        } else {
            entry.cont.resume(throwing: EngineError(message: msg["error"] as? String ?? "Unknown engine error"))
        }
    }

    private func loadModels() async {
        guard let r = try? await request("models"), let m = r["models"] as? [String: String] else { return }
        let order = ["deepfilternet3", "deepfilternet2", "rnnoise", "spectral"]
        models = m.map { ModelInfo(id: $0.key, label: $0.value) }
            .sorted { (order.firstIndex(of: $0.id) ?? 99, $0.id) < (order.firstIndex(of: $1.id) ?? 99, $1.id) }
    }

    private func terminated(_ proc: Process, code: Int32) {
        guard proc === process else { return }  // an old process from a restart
        process = nil
        input = nil
        buffer.removeAll()
        let detail = stderrTail.split(separator: "\n").last.map(String.init) ?? ""
        let msg = "The cleaning engine stopped (code \(code)). \(detail)".trimmingCharacters(in: .whitespaces)
        failPending(msg)
        if state != .stopped { fail(msg) }
    }

    private func failPending(_ msg: String) {
        for (_, entry) in pending { entry.cont.resume(throwing: EngineError(message: msg)) }
        pending.removeAll()
    }

    private func fail(_ msg: String) {
        state = .failed(msg)
        readyWaiters.forEach { $0.resume(throwing: EngineError(message: msg)) }
        readyWaiters.removeAll()
    }
}
