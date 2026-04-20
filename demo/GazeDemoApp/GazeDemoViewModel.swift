import Foundation
import GazeProtocolKit
import GazeProviderKit

@MainActor
final class GazeDemoViewModel: ObservableObject {
    @Published var stateText = "idle"
    @Published var confidenceText = "-"
    @Published var faceDistanceText = "-"
    @Published var originText = "-"
    @Published var directionText = "-"
    @Published var sampleCount = 0
    @Published var host = ""
    @Published var port = "9000"
    @Published var isStreaming = false
    @Published var logLines: [String] = []
    let shouldAutoStart: Bool
    let shouldAutoStream: Bool

    private let provider = GazeProvider()
    private var streamClient: ProviderStreamClient?

    init() {
        let environment = ProcessInfo.processInfo.environment
        shouldAutoStart = environment["GAZE_DEMO_AUTO_START"] == "1"
        shouldAutoStream = environment["GAZE_DEMO_AUTO_STREAM"] == "1"
        host = environment["GAZE_DEMO_HOST"] ?? ""
        port = environment["GAZE_DEMO_PORT"] ?? "9000"

        provider.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.stateText = String(describing: state)
                self?.appendLog("state=\(state)")
            }
        }

        provider.onSample = { [weak self] sample in
            Task { @MainActor [weak self] in
                self?.update(sample: sample)
            }
        }

        provider.onDiagnostic = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.appendLog(message)
            }
        }
    }

    func startTracking() {
        do {
            try provider.start()
            appendLog("tracking started")
        } catch {
            appendLog("start failed: \(error.localizedDescription)")
        }
    }

    func stopTracking() {
        provider.stop()
        appendLog("tracking stopped")
    }

    func setStreaming(enabled: Bool) {
        guard enabled else {
            streamClient?.stop()
            streamClient = nil
            provider.streamClient = nil
            appendLog("streaming disabled")
            return
        }

        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isStreaming = false
            appendLog("streaming failed: host is empty")
            return
        }
        guard let portValue = UInt16(port) else {
            isStreaming = false
            appendLog("streaming failed: invalid port")
            return
        }

        let client = ProviderStreamClient(host: host, port: portValue)
        client.start()
        streamClient = client
        provider.streamClient = client
        appendLog("streaming enabled to \(host):\(portValue)")
    }

    func startAutomaticSessionIfNeeded() {
        guard stateText == "idle" else {
            return
        }
        if shouldAutoStart {
            startTracking()
        }
        if shouldAutoStream && !isStreaming {
            isStreaming = true
            setStreaming(enabled: true)
        }
    }

    private func update(sample: ProviderSamplePayload) {
        sampleCount += 1
        confidenceText = String(format: "%.2f", sample.confidence)
        faceDistanceText = String(format: "%.3f m", sample.faceDistanceM)
        originText = format(sample.gazeOriginPM)
        directionText = format(sample.gazeDirP)
        if sampleCount == 1 {
            appendLog("first sample received")
        } else if sampleCount.isMultiple(of: 60) {
            appendLog("sampleCount=\(sampleCount)")
        }
    }

    private func format(_ values: [Float]) -> String {
        values.map { String(format: "%.3f", $0) }.joined(separator: ", ")
    }

    private func appendLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)"
        print(line)
        logLines.insert(line, at: 0)
        if logLines.count > 20 {
            logLines.removeLast(logLines.count - 20)
        }
    }
}
