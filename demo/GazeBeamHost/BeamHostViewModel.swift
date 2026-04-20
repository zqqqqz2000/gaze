import AppKit
import Foundation
import GazeProtocolKit
import QuartzCore

@MainActor
final class BeamHostViewModel: ObservableObject {
    @Published var serverStatus = "starting"
    @Published var connectionStatus = "waiting for iPhone"
    @Published var sampleCount = 0
    @Published var confidenceText = "-"
    @Published var pointText = "-"
    @Published var localAddresses: [String] = []
    @Published var overlayEnabled = true {
        didSet {
            overlayController.setVisible(overlayEnabled)
            appendLog(overlayEnabled ? "overlay enabled" : "overlay hidden")
        }
    }
    @Published var previewEnabled = false {
        didSet {
            configurePreviewTimer()
            appendLog(previewEnabled ? "preview motion enabled" : "preview motion disabled")
        }
    }
    @Published var beamSize: Double = 88 {
        didSet {
            overlayModel.baseRadius = CGFloat(beamSize)
        }
    }
    @Published var calibrationStatus = "uncalibrated"
    @Published var calibrationDetail = "run 9-point host calibration"
    @Published var logLines: [String] = []

    let listenerPort: UInt16 = 9000
    var hasCalibration: Bool { calibrationModel != nil }
    var isCalibrating: Bool { calibrationTask != nil }

    private let overlayModel = BeamOverlayModel()
    private lazy var overlayController = BeamOverlayWindowController(model: overlayModel)
    private let sampleServer = ProviderSampleServer()
    private let mapper = GazeScreenMapper()
    private let shouldAutoPreview = ProcessInfo.processInfo.environment["GAZE_BEAM_PREVIEW"] == "1"
    private var didStart = false
    private var previewTimer: Timer?
    private var calibrationModel: QuadraticCalibrationModel?
    private var calibrationCollector: CalibrationCollector?
    private var calibrationTask: Task<Void, Never>?
    private let calibrationPersistence = CalibrationPersistence()

    init() {
        overlayModel.baseRadius = CGFloat(beamSize)

        sampleServer.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }
    }

    func startIfNeeded() {
        guard !didStart else {
            return
        }
        didStart = true
        localAddresses = LocalIPAddressProvider.ipv4Addresses()
        overlayController.show()

        do {
            try sampleServer.start(port: listenerPort)
            serverStatus = "listening"
            appendLog("listening on \(listenerPort)")
        } catch {
            serverStatus = "failed"
            appendLog("listener failed: \(error.localizedDescription)")
        }

        restoreCalibrationIfAvailable()

        if shouldAutoPreview {
            previewEnabled = true
        }
    }

    private func handle(event: ProviderSampleServer.Event) {
        switch event {
        case .listenerReady(let port):
            serverStatus = "listening"
            appendLog("listener ready on \(port)")
        case .listenerFailed(let message):
            serverStatus = "failed"
            appendLog("listener failed: \(message)")
        case .clientConnected(let endpoint):
            connectionStatus = endpoint
            appendLog("client connected: \(endpoint)")
        case .clientDisconnected(let endpoint):
            connectionStatus = "waiting for iPhone"
            appendLog("client disconnected: \(endpoint)")
        case .receivedSample(let sample):
            consume(sample: sample)
        }
    }

    private func consume(sample: ProviderSamplePayload) {
        sampleCount += 1
        confidenceText = String(format: "%.2f", sample.confidence)
        let rawPoint = CalibrationRawPoint(
            sampleX: Double(sample.lookAtPointFM[0]),
            sampleY: Double(sample.lookAtPointFM[1])
        )
        collectCalibrationSampleIfNeeded(rawPoint: rawPoint, confidence: sample.confidence)

        let point = mapToScreen(rawPoint: rawPoint, sample: sample)
        pointText = String(format: "%.0f, %.0f", point.x, point.y)

        if !previewEnabled && sample.confidence >= 0.35 {
            overlayModel.setTarget(point)
        }

        if sampleCount == 1 {
            appendLog("first streamed sample received")
        } else if sampleCount.isMultiple(of: 120) {
            appendLog("sampleCount=\(sampleCount)")
        }
    }

    private var mainScreenFrame: CGRect {
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func startCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        calibrationModel = nil
        calibrationStatus = "starting calibration"
        calibrationDetail = "hold gaze on each target until it disappears"
        overlayEnabled = true
        previewEnabled = false

        calibrationTask = Task { @MainActor [weak self] in
            await self?.runCalibration()
        }
    }

    func clearCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        calibrationCollector = nil
        calibrationModel = nil
        overlayModel.setCalibrationTarget(nil)
        calibrationStatus = "uncalibrated"
        calibrationDetail = "run 9-point host calibration"
        do {
            try calibrationPersistence.clear()
        } catch {
            appendLog("failed to clear calibration: \(error.localizedDescription)")
        }
        appendLog("calibration cleared")
    }

    private func runCalibration() async {
        appendLog("calibration started")
        defer {
            calibrationCollector = nil
            overlayModel.setCalibrationTarget(nil)
            calibrationTask = nil
        }

        var fittedSamples: [QuadraticCalibrationSample] = []

        for (index, normalizedTarget) in CalibrationGrid.targets.enumerated() {
            if Task.isCancelled {
                calibrationStatus = "calibration cancelled"
                appendLog("calibration cancelled")
                return
            }

            calibrationStatus = "fixate \(index + 1)/\(CalibrationGrid.targets.count)"
            calibrationDetail = "waiting for stable samples"
            let targetPoint = screenPoint(fromNormalized: normalizedTarget)
            overlayModel.setCalibrationTarget(targetPoint)
            calibrationCollector = CalibrationCollector(
                stepIndex: index,
                targetNormalized: normalizedTarget,
                collectionStart: CACurrentMediaTime() + 0.45,
                collectionEnd: CACurrentMediaTime() + 1.15
            )

            try? await Task.sleep(nanoseconds: 1_250_000_000)

            guard let collector = calibrationCollector else {
                calibrationStatus = "calibration failed"
                calibrationDetail = "collector vanished before point \(index + 1)"
                appendLog("calibration collector disappeared at point \(index + 1)")
                return
            }

            guard let averagedPoint = collector.averageRawPoint(minimumCount: 10) else {
                calibrationStatus = "insufficient data at point \(index + 1)"
                calibrationDetail = "need at least 10 confident samples"
                appendLog("calibration failed at point \(index + 1): insufficient stable samples")
                return
            }

            fittedSamples.append(
                QuadraticCalibrationSample(
                    rawX: averagedPoint.x,
                    rawY: averagedPoint.y,
                    targetX: Double(normalizedTarget.x),
                    targetY: Double(normalizedTarget.y)
                )
            )
            appendLog("captured calibration point \(index + 1)/\(CalibrationGrid.targets.count)")
        }

        guard let calibrationModel = QuadraticCalibrationModel(samples: fittedSamples) else {
            calibrationStatus = "calibration fit failed"
            calibrationDetail = "quadratic fit became singular"
            appendLog("calibration fit failed")
            return
        }

        let rmsError = calibrationModel.rootMeanSquareError(samples: fittedSamples)
        self.calibrationModel = calibrationModel
        calibrationStatus = "calibration complete"
        calibrationDetail = String(format: "saved locally, rms %.4f", rmsError)
        do {
            try calibrationPersistence.save(calibrationModel)
        } catch {
            appendLog("failed to persist calibration: \(error.localizedDescription)")
        }
        appendLog("calibration complete")
    }

    private func configurePreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = nil

        guard previewEnabled else {
            return
        }

        let start = CACurrentMediaTime()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let elapsed = CACurrentMediaTime() - start
                let frame = self.mainScreenFrame
                let normalizedX = 0.5 + CGFloat(sin(elapsed * 0.9)) * 0.28
                let normalizedY = 0.5 + CGFloat(cos(elapsed * 1.4)) * 0.18 + CGFloat(sin(elapsed * 0.4)) * 0.06
                let point = CGPoint(
                    x: frame.minX + normalizedX * frame.width,
                    y: frame.maxY - normalizedY * frame.height
                )
                self.overlayModel.setTarget(point)
            }
        }
        RunLoop.main.add(previewTimer!, forMode: .common)
    }

    private func collectCalibrationSampleIfNeeded(rawPoint: CalibrationRawPoint, confidence: Float) {
        guard var collector = calibrationCollector else {
            return
        }
        guard confidence >= 0.45 else {
            return
        }

        let now = CACurrentMediaTime()
        guard now >= collector.collectionStart, now <= collector.collectionEnd else {
            return
        }

        collector.rawSamples.append(rawPoint)
        calibrationCollector = collector
        calibrationStatus = "fixate \(collector.stepIndex + 1)/\(CalibrationGrid.targets.count)"
        calibrationDetail = "\(collector.rawSamples.count) stable samples"
    }

    private func mapToScreen(rawPoint: CalibrationRawPoint, sample: ProviderSamplePayload) -> CGPoint {
        if let calibrationModel {
            let normalized = calibrationModel.map(rawX: rawPoint.x, rawY: rawPoint.y)
            return screenPoint(
                fromNormalized: CGPoint(
                    x: clamp(CGFloat(normalized.x), min: 0.03, max: 0.97),
                    y: clamp(CGFloat(normalized.y), min: 0.03, max: 0.97)
                )
            )
        }
        return mapper.map(sample: sample, in: mainScreenFrame)
    }

    private func screenPoint(fromNormalized normalizedPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: mainScreenFrame.minX + normalizedPoint.x * mainScreenFrame.width,
            y: mainScreenFrame.maxY - normalizedPoint.y * mainScreenFrame.height
        )
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    private func appendLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)"
        print(line)
        logLines.insert(line, at: 0)
        if logLines.count > 30 {
            logLines.removeLast(logLines.count - 30)
        }
    }

    private func restoreCalibrationIfAvailable() {
        do {
            guard let savedModel = try calibrationPersistence.load() else {
                return
            }
            calibrationModel = savedModel
            calibrationStatus = "calibration restored"
            calibrationDetail = "loaded saved host calibration"
            appendLog("restored saved calibration")
        } catch {
            calibrationStatus = "uncalibrated"
            calibrationDetail = "saved calibration could not be loaded"
            appendLog("failed to restore calibration: \(error.localizedDescription)")
        }
    }
}

private struct GazeScreenMapper {
    private let horizontalGain: CGFloat = 6.4
    private let verticalGain: CGFloat = 7.2
    private let verticalBias: CGFloat = 0.01
    private let inset: CGFloat = 0.04

    func map(sample: ProviderSamplePayload, in frame: CGRect) -> CGPoint {
        let rawX = CGFloat(sample.lookAtPointFM[0])
        let rawY = CGFloat(sample.lookAtPointFM[1])

        let normalizedX = clamp(0.5 + rawX * horizontalGain, min: inset, max: 1.0 - inset)
        let normalizedY = clamp(0.5 - (rawY - verticalBias) * verticalGain, min: inset, max: 1.0 - inset)

        return CGPoint(
            x: frame.minX + normalizedX * frame.width,
            y: frame.maxY - normalizedY * frame.height
        )
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }
}
