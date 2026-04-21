import Foundation
import GazeProtocolKit
import GazeProviderKit

@MainActor
final class GazeDemoViewModel: ObservableObject {
    enum StreamTransport: String, CaseIterable, Identifiable {
        case lan = "LAN"
        case usb = "USB"

        var id: String { rawValue }
    }

    @Published var stateText = "idle"
    @Published var confidenceText = "-"
    @Published var faceDistanceText = "-"
    @Published var originText = "-"
    @Published var directionText = "-"
    @Published var sampleCount = 0
    @Published var transportMode: StreamTransport = .lan {
        didSet {
            handleTransportModeChanged()
        }
    }
    @Published var host = ""
    @Published var port = "9000"
    @Published var isStreaming = false
    @Published var streamStatusText = "disabled"
    @Published var logLines: [String] = []
    let shouldAutoStart: Bool
    let shouldAutoStream: Bool
    let usbListenerPort: UInt16 = 9100

    private let provider = GazeProvider()
    private let usbBroadcastServer = ProviderSampleBroadcastServer()
    private var streamClient: ProviderStreamClient?

    init() {
        let environment = ProcessInfo.processInfo.environment
        shouldAutoStart = environment["GAZE_DEMO_AUTO_START"] == "1"
        shouldAutoStream = environment["GAZE_DEMO_AUTO_STREAM"] == "1"
        host = environment["GAZE_DEMO_HOST"] ?? ""
        port = environment["GAZE_DEMO_PORT"] ?? "9000"
        if environment["GAZE_DEMO_TRANSPORT"]?.lowercased() == "usb" {
            transportMode = .usb
        }

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

        usbBroadcastServer.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleUSBServerEvent(event)
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
            stopStreamingTransports()
            streamStatusText = "disabled"
            appendLog("streaming disabled")
            return
        }

        stopStreamingTransports()

        switch transportMode {
        case .lan:
            configureLANStreaming()
        case .usb:
            configureUSBStreaming()
        }
    }

    private func configureLANStreaming() {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isStreaming = false
            streamStatusText = "failed: host is empty"
            appendLog("streaming failed: host is empty")
            return
        }
        guard let portValue = UInt16(port) else {
            isStreaming = false
            streamStatusText = "failed: invalid port"
            appendLog("streaming failed: invalid port")
            return
        }

        let client = ProviderStreamClient(host: host, port: portValue)
        client.start()
        streamClient = client
        provider.streamClient = client
        streamStatusText = "streaming to \(host):\(portValue)"
        appendLog("streaming enabled to \(host):\(portValue)")
    }

    private func configureUSBStreaming() {
        do {
            try usbBroadcastServer.start(port: usbListenerPort)
            streamStatusText = "USB listening on device port \(usbListenerPort)"
            appendLog("USB streaming enabled on device port \(usbListenerPort)")
        } catch {
            isStreaming = false
            streamStatusText = "USB failed: \(error.localizedDescription)"
            appendLog("USB streaming failed: \(error.localizedDescription)")
        }
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

        if isStreaming && transportMode == .usb {
            usbBroadcastServer.broadcast(sample)
        }
    }

    private func format(_ values: [Float]) -> String {
        values.map { String(format: "%.3f", $0) }.joined(separator: ", ")
    }

    private func stopStreamingTransports() {
        streamClient?.stop()
        streamClient = nil
        provider.streamClient = nil
        usbBroadcastServer.stop()
    }

    private func handleTransportModeChanged() {
        appendLog("stream transport=\(transportMode.rawValue.lowercased())")
        guard isStreaming else {
            streamStatusText = transportMode == .lan ? "disabled" : "USB idle"
            return
        }
        setStreaming(enabled: true)
    }

    private func handleUSBServerEvent(_ event: ProviderSampleBroadcastServer.Event) {
        switch event {
        case .listenerReady(let port):
            streamStatusText = "USB listening on device port \(port)"
            appendLog("USB listener ready on device port \(port)")
        case .listenerFailed(let message):
            streamStatusText = "USB failed: \(message)"
            appendLog("USB listener failed: \(message)")
        case .clientConnected(let endpoint):
            streamStatusText = "USB connected: \(endpoint)"
            appendLog("USB client connected: \(endpoint)")
        case .clientDisconnected(let endpoint):
            streamStatusText = "USB listening on device port \(usbListenerPort)"
            appendLog("USB client disconnected: \(endpoint)")
        }
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
