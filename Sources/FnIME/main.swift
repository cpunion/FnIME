import AppKit
import AVFoundation
import ApplicationServices
import Foundation

private struct AppConfig {
    let apiKey: String
    let model: String
    let prompt: String
}

private struct FileConfig: Decodable {
    let apiKey: String?
    let model: String?
    let prompt: String?
}

private enum ConfigLoader {
    static let defaultModel = "gemini-3-flash-preview"
    static let defaultPrompt = "You are an input method ASR post-processor. Convert the user's speech into Chinese text for typing. Infer the domain only from the spoken content in this audio, then use that inferred domain to disambiguate jargon, proper nouns, and abbreviations/acronyms. Prefer the interpretation that best matches local context. If uncertain, keep the original wording or abbreviation. Apply only light polishing (punctuation, filler removal, obvious ASR fixes) without changing user intent or adding facts. Return plain text only."

    static func load() -> AppConfig? {
        let env = ProcessInfo.processInfo.environment
        var apiKey = env["GEMINI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var model = env["GEMINI_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var prompt = env["GEMINI_PROMPT"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let fileURL = configFileURL(),
           let data = try? Data(contentsOf: fileURL),
           let fileConfig = try? JSONDecoder().decode(FileConfig.self, from: data) {
            if apiKey.isEmpty {
                apiKey = fileConfig.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if model.isEmpty {
                model = fileConfig.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if prompt.isEmpty {
                prompt = fileConfig.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        }

        guard !apiKey.isEmpty else {
            return nil
        }

        if model.isEmpty {
            model = defaultModel
        }
        if prompt.isEmpty {
            prompt = defaultPrompt
        }

        return AppConfig(
            apiKey: apiKey,
            model: model,
            prompt: prompt
        )
    }

    static func configFileURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/fn-ime/config.json")
    }
}

private final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "fnime.logger")
    private let fileURL: URL

    var logPath: String { fileURL.path }

    private init() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let preferredDir = home.appendingPathComponent(".local/state/fn-ime", isDirectory: true)
        let preferredFile = preferredDir.appendingPathComponent("fn-ime.log")

        do {
            try fileManager.createDirectory(at: preferredDir, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: preferredFile.path) {
                fileManager.createFile(atPath: preferredFile.path, contents: nil)
            }
            fileURL = preferredFile
        } catch {
            let fallback = URL(fileURLWithPath: "/tmp/fn-ime.log")
            if !fileManager.fileExists(atPath: fallback.path) {
                fileManager.createFile(atPath: fallback.path, contents: nil)
            }
            fileURL = fallback
        }
    }

    func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private func write(level: String, message: String) {
        let line = "[\(Self.timestamp())] [\(level)] \(message)\n"

        queue.async { [fileURL] in
            fputs(line, stderr)
            guard let data = line.data(using: .utf8) else { return }

            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                fputs("[\(Self.timestamp())] [ERROR] Logger write failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private enum RecorderError: LocalizedError {
    case microphonePermissionDenied
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied"
        case let .engineStartFailed(message):
            return "Audio engine start failed: \(message)"
        }
    }
}

private struct RecordedAudio {
    let wavData: Data
    let sampleRate: Int
    let sampleCount: Int

    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / Double(sampleRate)
    }
}

private final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let bufferQueue = DispatchQueue(label: "fnime.audio.buffer")

    private var samples: [Float] = []
    private var sampleRate: Double = 44_100
    private var isRecording = false
    var levelHandler: (@Sendable (Float) -> Void)?

    func start() throws {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard auth == .authorized else {
            throw RecorderError.microphonePermissionDenied
        }

        guard !isRecording else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        bufferQueue.sync {
            samples.removeAll(keepingCapacity: true)
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() -> RecordedAudio? {
        guard isRecording else { return nil }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let levelHandler {
            DispatchQueue.main.async {
                levelHandler(0)
            }
        }

        let copiedSamples: [Float] = bufferQueue.sync { samples }
        guard !copiedSamples.isEmpty else {
            return nil
        }

        let rate = Int(sampleRate)
        return RecordedAudio(
            wavData: wavData(from: copiedSamples, sampleRate: rate, channels: 1),
            sampleRate: rate,
            sampleCount: copiedSamples.count
        )
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var energySum: Float = 0

        bufferQueue.sync {
            for frame in 0 ..< frameCount {
                var mixed: Float = 0
                for channel in 0 ..< channelCount {
                    mixed += channelData[channel][frame]
                }
                mixed /= Float(max(channelCount, 1))
                samples.append(mixed)
                energySum += mixed * mixed
            }
        }

        if frameCount > 0, let levelHandler {
            let rms = sqrt(energySum / Float(frameCount))
            let normalized = max(0, min(1, rms * 12))
            DispatchQueue.main.async {
                levelHandler(normalized)
            }
        }
    }

    private func wavData(from floatSamples: [Float], sampleRate: Int, channels: Int) -> Data {
        var pcm = Data(capacity: floatSamples.count * MemoryLayout<Int16>.size)
        for sample in floatSamples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = Int16(clamped * Float(Int16.max))
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { rawBytes in
                pcm.append(contentsOf: rawBytes)
            }
        }

        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let subchunk2Size = pcm.count
        let chunkSize = 36 + subchunk2Size

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.appendLE(UInt32(chunkSize))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.appendLE(UInt32(16))
        header.appendLE(UInt16(1))
        header.appendLE(UInt16(channels))
        header.appendLE(UInt32(sampleRate))
        header.appendLE(UInt32(byteRate))
        header.appendLE(UInt16(blockAlign))
        header.appendLE(UInt16(bitsPerSample))
        header.append("data".data(using: .ascii)!)
        header.appendLE(UInt32(subchunk2Size))

        header.append(pcm)
        return header
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private enum GeminiClientError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case decodeError
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Gemini API"
        case let .httpError(code, message):
            return "Gemini API error (\(code)): \(message)"
        case .decodeError:
            return "Failed to decode Gemini API response"
        case .emptyResult:
            return "Gemini returned empty text"
        }
    }
}

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }

            let parts: [Part]?
        }

        let content: Content?
    }

    let candidates: [Candidate]?
}

private struct GeminiErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

private final class GeminiClient {
    private let apiKey: String
    private let model: String
    private let prompt: String

    init(config: AppConfig) {
        apiKey = config.apiKey
        model = config.model
        prompt = config.prompt
    }

    @discardableResult
    func transcribe(wavData: Data, completion: @escaping @Sendable (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        let requestID = String(UUID().uuidString.prefix(8))
        AppLogger.shared.info("Gemini request \(requestID) start model=\(model) wavBytes=\(wavData.count)")

        let escapedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escapedModel):generateContent?key=\(apiKey)") else {
            AppLogger.shared.error("Gemini request \(requestID) invalid URL")
            completion(.failure(GeminiClientError.invalidResponse))
            return nil
        }

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inlineData": [
                                "mimeType": "audio/wav",
                                "data": wavData.base64EncodedString()
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            AppLogger.shared.error("Gemini request \(requestID) payload encode failed")
            completion(.failure(GeminiClientError.invalidResponse))
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                AppLogger.shared.error("Gemini request \(requestID) network error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let data else {
                AppLogger.shared.error("Gemini request \(requestID) invalid response")
                completion(.failure(GeminiClientError.invalidResponse))
                return
            }

            AppLogger.shared.info("Gemini request \(requestID) response status=\(httpResponse.statusCode) bytes=\(data.count)")

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                let message: String
                if let decodedError = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data),
                   let apiMessage = decodedError.error?.message,
                   !apiMessage.isEmpty {
                    message = apiMessage
                } else {
                    message = String(data: data, encoding: .utf8) ?? "Unknown error"
                }
                AppLogger.shared.error("Gemini request \(requestID) failed: \(Self.logSafe(message))")
                completion(.failure(GeminiClientError.httpError(httpResponse.statusCode, message)))
                return
            }

            guard let decoded = try? JSONDecoder().decode(GeminiResponse.self, from: data) else {
                AppLogger.shared.error("Gemini request \(requestID) decode failed")
                completion(.failure(GeminiClientError.decodeError))
                return
            }

            let text = decoded.candidates?
                .first?
                .content?
                .parts?
                .compactMap { $0.text }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !text.isEmpty else {
                AppLogger.shared.error("Gemini request \(requestID) empty text")
                completion(.failure(GeminiClientError.emptyResult))
                return
            }

            AppLogger.shared.info("Gemini request \(requestID) success textChars=\(text.count)")
            completion(.success(text))
        }
        task.resume()
        return task
    }

    private static func logSafe(_ text: String, maxLen: Int = 200) -> String {
        if text.count <= maxLen {
            return text
        }
        return String(text.prefix(maxLen)) + "..."
    }
}

private final class FnKeyMonitor: @unchecked Sendable {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var statePollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "fnime.fn.monitor")

    private var isFnPressed = false
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
        startStatePolling()
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        statePollTimer?.cancel()
        statePollTimer = nil
    }

    private func handle(_ event: NSEvent) {
        syncStateFromEvent(currentlyPressed: event.modifierFlags.contains(.function))
    }

    private func startStatePolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(150), repeating: .milliseconds(120))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let currentlyPressed = flags.contains(.maskSecondaryFn)
            self.syncStateFromPoll(currentlyPressed: currentlyPressed)
        }
        statePollTimer = timer
        timer.resume()
    }

    private func syncStateFromEvent(currentlyPressed: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard currentlyPressed != self.isFnPressed else {
                return
            }
            self.isFnPressed = currentlyPressed
            self.onChange(currentlyPressed)
        }
    }

    // Polling is only a release-safety net to recover when fn-up event is lost.
    // It must not synthesize fn-down, otherwise random false positives can trigger recording.
    private func syncStateFromPoll(currentlyPressed: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isFnPressed, !currentlyPressed else {
                return
            }
            self.isFnPressed = false
            self.onChange(false)
        }
    }
}

private final class TextInjector {
    private let vKeyCode: CGKeyCode = 9
    private let commandKeyCode: CGKeyCode = 55

    func inject(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        return simulateCommandV()
    }

    private func simulateCommandV() -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false) else {
            return false
        }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        commandDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)

        return true
    }
}

private final class RecognitionStatsStore: @unchecked Sendable {
    private struct Sample: Codable {
        let audioSeconds: Double
        let transcribeSeconds: Double
        let createdAt: Date
    }

    private let queue = DispatchQueue(label: "fnime.stats")
    private let fileURL: URL
    private var samples: [Sample] = []

    init() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".local/state/fn-ime", isDirectory: true)
        fileURL = dir.appendingPathComponent("recognition-stats.json")

        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode([Sample].self, from: data) {
                samples = decoded
            }
        } catch {
            AppLogger.shared.error("Stats store init failed: \(error.localizedDescription)")
        }
    }

    func estimateTranscribeSeconds(for audioSeconds: Double) -> Double {
        queue.sync {
            estimateLocked(for: max(0.05, audioSeconds))
        }
    }

    func record(audioSeconds: Double, transcribeSeconds: Double) {
        let sample = Sample(
            audioSeconds: max(0.01, audioSeconds),
            transcribeSeconds: max(0.01, transcribeSeconds),
            createdAt: Date()
        )

        queue.async { [weak self] in
            guard let self else { return }
            self.samples.append(sample)
            if self.samples.count > 80 {
                self.samples.removeFirst(self.samples.count - 80)
            }
            self.persistLocked()
        }
    }

    private func estimateLocked(for audioSeconds: Double) -> Double {
        let valid = samples.filter { $0.audioSeconds > 0.05 && $0.transcribeSeconds > 0.05 }

        if let regressed = linearRegressionEstimate(for: audioSeconds, samples: valid) {
            return clampEstimate(regressed)
        }

        if !valid.isEmpty {
            let avg = valid.map(\.transcribeSeconds).reduce(0, +) / Double(valid.count)
            return clampEstimate(avg)
        }

        let coldStart = 0.7 + audioSeconds * 0.9
        return clampEstimate(coldStart)
    }

    private func linearRegressionEstimate(for audioSeconds: Double, samples: [Sample]) -> Double? {
        guard samples.count >= 3 else { return nil }

        let n = Double(samples.count)
        let sumX = samples.map(\.audioSeconds).reduce(0, +)
        let sumY = samples.map(\.transcribeSeconds).reduce(0, +)
        let sumXY = samples.reduce(0) { $0 + $1.audioSeconds * $1.transcribeSeconds }
        let sumXX = samples.reduce(0) { $0 + $1.audioSeconds * $1.audioSeconds }

        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > 0.000_001 else { return nil }

        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n
        let estimated = intercept + slope * audioSeconds
        return estimated.isFinite ? estimated : nil
    }

    private func clampEstimate(_ value: Double) -> Double {
        max(0.6, min(12.0, value))
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(samples) else {
            AppLogger.shared.error("Stats encode failed")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.shared.error("Stats persist failed: \(error.localizedDescription)")
        }
    }
}

@MainActor
private final class FloatingStatusOverlay {
    private final class SpectrumBarsView: NSView {
        private var bars = Array(repeating: CGFloat(0.08), count: 20)
        private var phase: CGFloat = 0

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 30)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            nil
        }

        func update(level: Float) {
            let normalized = CGFloat(max(0, min(1, level)))
            phase += 0.22
            for idx in bars.indices {
                let wave = abs(sin(phase + CGFloat(idx) * 0.6))
                let noise = CGFloat.random(in: 0 ... max(0.02, normalized * 0.08))
                let target = max(0.07, min(0.98, normalized * (0.35 + 0.65 * wave) + noise))
                bars[idx] = bars[idx] * 0.72 + target * 0.28
            }
            needsDisplay = true
        }

        func reset() {
            for idx in bars.indices {
                bars[idx] = 0.08
            }
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let drawingRect = bounds.insetBy(dx: 1, dy: 2)
            guard drawingRect.width > 0, drawingRect.height > 0 else { return }

            let gap: CGFloat = 3
            let totalGap = gap * CGFloat(max(0, bars.count - 1))
            let barWidth = max(2, (drawingRect.width - totalGap) / CGFloat(bars.count))
            let radius = min(barWidth / 2, 3)

            NSColor.white.withAlphaComponent(0.85).setFill()
            for (idx, value) in bars.enumerated() {
                let height = max(2, drawingRect.height * value)
                let x = drawingRect.minX + CGFloat(idx) * (barWidth + gap)
                let y = drawingRect.midY - height / 2
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()
            }
        }
    }

    private final class SmoothProgressBarView: NSView {
        private let trackLayer = CALayer()
        private let fillLayer = CALayer()
        private var progress: CGFloat = 0

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 10)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false

            trackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.20).cgColor
            fillLayer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.95).cgColor
            layer?.addSublayer(trackLayer)
            layer?.addSublayer(fillLayer)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let trackRect = bounds
            trackLayer.frame = trackRect
            trackLayer.cornerRadius = trackRect.height / 2
            trackLayer.masksToBounds = true
            applyProgress(progress, animated: false)
            CATransaction.commit()
        }

        func setProgress(_ value: Double, animated: Bool) {
            applyProgress(CGFloat(max(0, min(1, value))), animated: animated)
        }

        private func applyProgress(_ value: CGFloat, animated: Bool) {
            progress = value
            let width = bounds.width * progress
            let fillRect = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            if animated {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.12)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                fillLayer.frame = fillRect
                fillLayer.cornerRadius = fillRect.height / 2
                fillLayer.masksToBounds = true
                CATransaction.commit()
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                fillLayer.frame = fillRect
                fillLayer.cornerRadius = fillRect.height / 2
                fillLayer.masksToBounds = true
                CATransaction.commit()
            }
        }
    }

    private final class OverlayContentView: NSView {
        var onRetry: (() -> Void)?
        var onCancel: (() -> Void)?

        private let iconView = NSImageView()
        private let titleLabel = NSTextField(labelWithString: "")
        private let subtitleLabel = NSTextField(labelWithString: "")
        private let progressBar = SmoothProgressBarView(frame: .zero)
        private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
        private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        private let spectrumView = SpectrumBarsView(frame: .zero)
        private let buttonRow = NSStackView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 16
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.80).cgColor

            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .systemRed

            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
            titleLabel.textColor = .white

            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.82)

            progressBar.translatesAutoresizingMaskIntoConstraints = false
            progressBar.setProgress(0, animated: false)
            progressBar.isHidden = true
            progressBar.heightAnchor.constraint(equalToConstant: 10).isActive = true

            retryButton.translatesAutoresizingMaskIntoConstraints = false
            retryButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            retryButton.bezelStyle = .rounded
            retryButton.target = self
            retryButton.action = #selector(onRetryPressed)
            retryButton.isHidden = true

            cancelButton.translatesAutoresizingMaskIntoConstraints = false
            cancelButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            cancelButton.bezelStyle = .rounded
            cancelButton.target = self
            cancelButton.action = #selector(onCancelPressed)
            cancelButton.isHidden = true

            spectrumView.translatesAutoresizingMaskIntoConstraints = false
            spectrumView.heightAnchor.constraint(equalToConstant: 30).isActive = true

            buttonRow.orientation = .horizontal
            buttonRow.alignment = .centerY
            buttonRow.distribution = .fill
            buttonRow.spacing = 8
            buttonRow.translatesAutoresizingMaskIntoConstraints = false

            let spacer = NSView(frame: .zero)
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 74).isActive = true
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 74).isActive = true

            buttonRow.addArrangedSubview(cancelButton)
            buttonRow.addArrangedSubview(spacer)
            buttonRow.addArrangedSubview(retryButton)
            buttonRow.isHidden = true

            let textStack = NSStackView(views: [titleLabel, subtitleLabel])
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 2
            textStack.translatesAutoresizingMaskIntoConstraints = false

            let headerRow = NSStackView(views: [iconView, textStack])
            headerRow.orientation = .horizontal
            headerRow.alignment = .top
            headerRow.spacing = 10
            headerRow.translatesAutoresizingMaskIntoConstraints = false

            let rootStack = NSStackView(views: [headerRow, spectrumView, progressBar, buttonRow])
            rootStack.orientation = .vertical
            rootStack.alignment = .leading
            rootStack.spacing = 8
            rootStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
            rootStack.translatesAutoresizingMaskIntoConstraints = false

            addSubview(rootStack)
            NSLayoutConstraint.activate([
                rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
                rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
                rootStack.topAnchor.constraint(equalTo: topAnchor),
                rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),

                iconView.widthAnchor.constraint(equalToConstant: 28),
                iconView.heightAnchor.constraint(equalToConstant: 28),

                textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
                spectrumView.widthAnchor.constraint(equalTo: textStack.widthAnchor),
                progressBar.widthAnchor.constraint(equalTo: textStack.widthAnchor),
                buttonRow.widthAnchor.constraint(equalTo: textStack.widthAnchor)
            ])
        }

        required init?(coder: NSCoder) {
            nil
        }

        @objc private func onRetryPressed() {
            onRetry?()
        }

        @objc private func onCancelPressed() {
            onCancel?()
        }

        func showRecording() {
            iconView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
            iconView.contentTintColor = .systemRed
            titleLabel.stringValue = "Recording"
            subtitleLabel.stringValue = "Release fn to transcribe"
            spectrumView.reset()
            spectrumView.isHidden = false
            progressBar.isHidden = true
            buttonRow.isHidden = true
            retryButton.isHidden = true
            cancelButton.isHidden = true
        }

        func showTranscribing(estimatedSeconds: Double) {
            iconView.image = NSImage(systemSymbolName: "waveform.and.magnifyingglass", accessibilityDescription: nil)
            iconView.contentTintColor = .systemBlue
            titleLabel.stringValue = "Recognizing"
            subtitleLabel.stringValue = String(format: "Estimated %.1fs", estimatedSeconds)
            progressBar.setProgress(0.03, animated: false)
            spectrumView.isHidden = true
            progressBar.isHidden = false
            buttonRow.isHidden = false
            retryButton.isHidden = true
            cancelButton.title = "Cancel"
            cancelButton.isHidden = false
        }

        func updateSpectrum(level: Float) {
            spectrumView.update(level: level)
        }

        func updateProgress(_ fraction: Double) {
            progressBar.setProgress(fraction, animated: true)
        }

        func finish(success: Bool) {
            iconView.image = NSImage(systemSymbolName: success ? "checkmark.circle.fill" : "xmark.circle.fill", accessibilityDescription: nil)
            iconView.contentTintColor = success ? .systemGreen : .systemOrange
            titleLabel.stringValue = success ? "Done" : "Failed"
            subtitleLabel.stringValue = success ? "Inserted to current cursor" : "See logs for details"
            progressBar.setProgress(1.0, animated: true)
            spectrumView.isHidden = true
            progressBar.isHidden = false
            buttonRow.isHidden = true
            retryButton.isHidden = true
            cancelButton.isHidden = true
        }

        func showRetry(reason: String) {
            iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            iconView.contentTintColor = .systemYellow
            titleLabel.stringValue = "Recognition Timeout"
            subtitleLabel.stringValue = reason
            spectrumView.isHidden = true
            progressBar.isHidden = true
            buttonRow.isHidden = false
            retryButton.isHidden = false
            cancelButton.title = "Abort"
            cancelButton.isHidden = false
        }
    }

    private let panel: NSPanel
    private let contentView: OverlayContentView

    private var progressTimer: Timer?
    private var progressStartUptime: TimeInterval?
    private var estimatedSeconds: Double = 1.5
    private var displayedProgress: Double = 0

    init() {
        let width: CGFloat = 360
        let height: CGFloat = 118
        contentView = OverlayContentView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        panel = NSPanel(
            contentRect: contentView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = contentView
    }

    func showRecording() {
        stopProgressTimer()
        contentView.showRecording()
        resizePanelToFitContent()
        placeAtBottomCenter()
        panel.orderFrontRegardless()
    }

    func showTranscribing(estimatedSeconds: Double) {
        stopProgressTimer()
        self.estimatedSeconds = max(0.6, min(12.0, estimatedSeconds))
        progressStartUptime = ProcessInfo.processInfo.systemUptime
        displayedProgress = 0.03
        contentView.showTranscribing(estimatedSeconds: self.estimatedSeconds)
        contentView.updateProgress(displayedProgress)
        resizePanelToFitContent()
        placeAtBottomCenter()
        panel.orderFrontRegardless()
        startProgressTimer()
    }

    func showRetry(reason: String) {
        stopProgressTimer()
        contentView.showRetry(reason: reason)
        resizePanelToFitContent()
        placeAtBottomCenter()
        panel.orderFrontRegardless()
    }

    func updateRecordingLevel(_ level: Float) {
        contentView.updateSpectrum(level: level)
    }

    func setRetryHandler(_ handler: @escaping () -> Void) {
        contentView.onRetry = handler
    }

    func setCancelHandler(_ handler: @escaping () -> Void) {
        contentView.onCancel = handler
    }

    func finishTranscribing(success: Bool) {
        stopProgressTimer()
        contentView.finish(success: success)
        resizePanelToFitContent()
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.hide()
        }
    }

    func hide() {
        stopProgressTimer()
        panel.orderOut(nil)
    }

    private func startProgressTimer() {
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(handleProgressTimer),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 1.0 / 120.0
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        progressStartUptime = nil
        displayedProgress = 0
    }

    @objc private func handleProgressTimer() {
        tickProgress()
    }

    private func tickProgress() {
        guard let progressStartUptime else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - progressStartUptime
        let raw = elapsed / max(estimatedSeconds, 0.1)
        let capped = min(0.92, raw)
        let target = 1 - pow(1 - capped, 2)
        // Low-pass interpolation keeps perceived movement continuous even under timer jitter.
        displayedProgress += (target - displayedProgress) * 0.22
        contentView.updateProgress(displayedProgress)
    }

    private func resizePanelToFitContent() {
        contentView.layoutSubtreeIfNeeded()
        let fitting = contentView.fittingSize
        let width = max(360, fitting.width)
        let height = max(108, fitting.height)
        panel.setContentSize(NSSize(width: width, height: height))
    }

    private func placeAtBottomCenter() {
        guard let targetScreen = screenForOverlay() else { return }
        let visible = targetScreen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenForOverlay() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let matched = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return matched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

@MainActor
private final class AppController: NSObject, NSApplicationDelegate {
    private let recorder = AudioRecorder()
    private let injector = TextInjector()
    private let overlay = FloatingStatusOverlay()
    private let statsStore = RecognitionStatsStore()
    private var monitor: FnKeyMonitor?

    private var client: GeminiClient?
    private var isRecording = false
    private var isTranscribing = false
    private var currentTranscriptionID: UUID?
    private var currentTranscribeTask: URLSessionDataTask?
    private var transcribeTimeoutTimer: Timer?
    private var lastRecordingForRetry: RecordedAudio?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private let hintMenuItem = NSMenuItem(title: "Hold fn to talk, use HUD Cancel to stop recognition", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.info("FnIME launching, logPath=\(AppLogger.shared.logPath)")
        recorder.levelHandler = { [weak self] level in
            Task { @MainActor in
                self?.overlay.updateRecordingLevel(level)
            }
        }
        setupMenu()
        setupPermissions()
        loadConfig()
        overlay.setRetryHandler { [weak self] in
            Task { @MainActor in
                self?.retryLastTranscription()
            }
        }
        overlay.setCancelHandler { [weak self] in
            Task { @MainActor in
                self?.handleCancelPressed()
            }
        }

        let newMonitor = FnKeyMonitor { [weak self] isDown in
            Task { @MainActor in
                self?.handleFnState(isDown: isDown)
            }
        }
        newMonitor.start()
        monitor = newMonitor
        AppLogger.shared.info("Fn key monitor started")

        if client != nil {
            updateState("Idle")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        cancelCurrentTranscriptionAndClearState()
        overlay.hide()
        AppLogger.shared.info("FnIME terminated")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func setupMenu() {
        statusItem.button?.title = "FnIME"

        let menu = NSMenu()
        menu.addItem(stateMenuItem)
        menu.addItem(hintMenuItem)
        menu.addItem(NSMenuItem.separator())

        let configPath = ConfigLoader.configFileURL()?.path ?? "~/.config/fn-ime/config.json"
        let configItem = NSMenuItem(title: "Config: \(configPath)", action: nil, keyEquivalent: "")
        configItem.isEnabled = false
        menu.addItem(configItem)
        let logItem = NSMenuItem(title: "Log: \(AppLogger.shared.logPath)", action: nil, keyEquivalent: "")
        logItem.isEnabled = false
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setupPermissions() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let axTrusted = AXIsProcessTrustedWithOptions(options)
        AppLogger.shared.info("Accessibility trusted=\(axTrusted)")

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        AppLogger.shared.info("Microphone auth status=\(micStatus.rawValue)")

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            AppLogger.shared.info("Microphone access callback granted=\(granted)")
        }
    }

    private func loadConfig() {
        guard let config = ConfigLoader.load() else {
            updateState("Missing GEMINI_API_KEY")
            AppLogger.shared.error("Config missing GEMINI_API_KEY")
            client = nil
            return
        }
        AppLogger.shared.info("Config loaded model=\(config.model) promptChars=\(config.prompt.count)")
        client = GeminiClient(config: config)
    }

    private func handleFnState(isDown: Bool) {
        AppLogger.shared.info("Fn state changed down=\(isDown) recording=\(isRecording) transcribing=\(isTranscribing)")
        if isTranscribing {
            AppLogger.shared.info("Ignored fn event while transcribing")
            return
        }

        if isDown {
            startRecordingIfNeeded()
        } else {
            stopRecordingAndTranscribeIfNeeded()
        }
    }

    private func startRecordingIfNeeded() {
        guard !isRecording else { return }

        guard client != nil else {
            updateState("No API key")
            AppLogger.shared.error("Cannot record without API client")
            return
        }

        do {
            try recorder.start()
            isRecording = true
            updateState("Recording...")
            overlay.showRecording()
            AppLogger.shared.info("Recording started")
        } catch {
            updateState("Record failed: \(error.localizedDescription)")
            overlay.hide()
            AppLogger.shared.error("Recording start failed: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribeIfNeeded() {
        guard isRecording else { return }

        isRecording = false
        guard let recording = recorder.stop(), recording.wavData.count > 44 else {
            updateState("No audio captured")
            overlay.hide()
            AppLogger.shared.error("Recording stopped with empty audio")
            return
        }

        AppLogger.shared.info(
            "Recording stopped duration=\(String(format: "%.2f", recording.durationSeconds))s sampleRate=\(recording.sampleRate) samples=\(recording.sampleCount) wavBytes=\(recording.wavData.count)"
        )
        startTranscribing(recording: recording, trigger: "fn-release")
    }

    private func startTranscribing(recording: RecordedAudio, trigger: String) {
        guard let client else {
            updateState("No API client")
            overlay.finishTranscribing(success: false)
            AppLogger.shared.error("Cannot transcribe (\(trigger)): API client missing")
            return
        }

        if isTranscribing {
            AppLogger.shared.info("Skip transcribing (\(trigger)) because one request is already running")
            return
        }

        let estimated = statsStore.estimateTranscribeSeconds(for: recording.durationSeconds)
        let timeout = timeoutInterval(forEstimated: estimated)

        lastRecordingForRetry = recording
        isTranscribing = true
        let transcriptionID = UUID()
        currentTranscriptionID = transcriptionID

        overlay.showTranscribing(estimatedSeconds: estimated)
        updateState("Transcribing...")
        AppLogger.shared.info("Transcribing started trigger=\(trigger) estimate=\(String(format: "%.2f", estimated))s timeout=\(String(format: "%.2f", timeout))s")

        scheduleTimeout(for: transcriptionID, after: timeout)

        let audioDuration = recording.durationSeconds
        let transcribeStartedAt = Date()
        currentTranscribeTask = client.transcribe(wavData: recording.wavData) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.currentTranscriptionID == transcriptionID else {
                    AppLogger.shared.info("Ignore stale transcription callback id=\(transcriptionID)")
                    return
                }

                self.clearTranscriptionRuntimeState()

                let transcribeCost = Date().timeIntervalSince(transcribeStartedAt)
                self.statsStore.record(audioSeconds: audioDuration, transcribeSeconds: transcribeCost)
                AppLogger.shared.info(
                    "Transcribing finished cost=\(String(format: "%.2f", transcribeCost))s forAudio=\(String(format: "%.2f", audioDuration))s"
                )

                switch result {
                case let .success(text):
                    let pasted = self.injector.inject(text)
                    if pasted {
                        self.updateState("Inserted: \(Self.short(text))")
                        self.overlay.hide()
                        AppLogger.shared.info("Inject success textChars=\(text.count)")
                    } else {
                        self.updateState("Copied only: \(Self.short(text))")
                        self.overlay.hide()
                        AppLogger.shared.info("Inject fallback copied-only textChars=\(text.count)")
                    }
                case let .failure(error):
                    self.updateState("Transcribe failed: \(error.localizedDescription)")
                    self.overlay.finishTranscribing(success: false)
                    AppLogger.shared.error("Transcribe failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func scheduleTimeout(for transcriptionID: UUID, after timeout: Double) {
        transcribeTimeoutTimer?.invalidate()
        transcribeTimeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleTranscriptionTimeout(transcriptionID: transcriptionID, timeout: timeout)
            }
        }
    }

    private func timeoutInterval(forEstimated estimated: Double) -> Double {
        let relaxed = max(estimated * 2.4, estimated + 3.5)
        return min(40, max(5, relaxed))
    }

    private func handleTranscriptionTimeout(transcriptionID: UUID, timeout: Double) {
        guard isTranscribing, currentTranscriptionID == transcriptionID else {
            return
        }

        AppLogger.shared.error("Transcription timeout id=\(transcriptionID) after=\(String(format: "%.2f", timeout))s")
        cancelCurrentTranscriptionAndClearState()
        updateState("Transcribe timeout")
        overlay.showRetry(reason: "Took longer than expected. Press Retry.")
    }

    private func handleCancelPressed() {
        if isTranscribing {
            AppLogger.shared.info("Cancel button pressed, cancel current transcription")
            cancelCurrentTranscriptionAndClearState()
            updateState("Transcribe cancelled")
            overlay.hide()
        } else {
            AppLogger.shared.info("Abort button pressed on timeout panel")
            overlay.hide()
            if client != nil {
                updateState("Idle")
            }
        }
    }

    private func retryLastTranscription() {
        guard !isRecording else {
            AppLogger.shared.info("Retry ignored because recording is active")
            return
        }
        guard !isTranscribing else {
            AppLogger.shared.info("Retry ignored because transcription is active")
            return
        }
        guard let recording = lastRecordingForRetry else {
            AppLogger.shared.error("Retry requested but no previous recording")
            overlay.hide()
            return
        }
        AppLogger.shared.info("Retry transcription requested")
        startTranscribing(recording: recording, trigger: "retry-button")
    }

    private func cancelCurrentTranscriptionAndClearState() {
        currentTranscribeTask?.cancel()
        clearTranscriptionRuntimeState()
    }

    private func clearTranscriptionRuntimeState() {
        isTranscribing = false
        currentTranscriptionID = nil
        currentTranscribeTask = nil
        transcribeTimeoutTimer?.invalidate()
        transcribeTimeoutTimer = nil
    }

    private static func short(_ text: String) -> String {
        if text.count <= 24 {
            return text
        }
        return String(text.prefix(24)) + "..."
    }

    private func updateState(_ text: String) {
        stateMenuItem.title = text
        AppLogger.shared.info("State updated: \(text)")
    }
}

@main
private struct FnIMEMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppController()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
