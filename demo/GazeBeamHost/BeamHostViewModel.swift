import AppKit
import Foundation
import GazeCoreKit
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
    var hasCalibration: Bool { calibration != nil }
    var isCalibrating: Bool { calibrationTask != nil }

    private let overlayModel = BeamOverlayModel()
    private lazy var overlayController = BeamOverlayWindowController(model: overlayModel)
    private let sampleServer = ProviderSampleServer()
    private let uncalibratedMapper = GazeScreenMapper()
    private let shouldAutoPreview = ProcessInfo.processInfo.environment["GAZE_BEAM_PREVIEW"] == "1"
    private var didStart = false
    private var previewTimer: Timer?
    private var calibration: GazeCalibration?
    private var calibrationCollector: CalibrationCollector?
    private var calibrationTask: Task<Void, Never>?
    private let calibrationPersistence = CalibrationPersistence()
    private var lastRuntimeStatus = "idle"

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
            overlayModel.clearTarget()
            appendLog("client disconnected: \(endpoint)")
        case .receivedSample(let sample):
            consume(sample: sample)
        }
    }

    private func consume(sample: ProviderSamplePayload) {
        sampleCount += 1
        confidenceText = String(format: "%.2f", sample.confidence)
        collectCalibrationSampleIfNeeded(sample: sample)

        guard let mappedPoint = mapToScreen(sample: sample) else {
            pointText = "-"
            if !previewEnabled {
                overlayModel.clearTarget()
            }
            return
        }

        pointText = mappedPoint.debugDescription

        if !previewEnabled && sample.confidence >= 0.35 && sample.trackingFlags == 1 {
            overlayModel.setTarget(mappedPoint.point)
        } else if !previewEnabled {
            overlayModel.clearTarget()
        }

        if sampleCount == 1 {
            appendLog("first streamed sample received")
        } else if sampleCount.isMultiple(of: 120) {
            appendLog("sampleCount=\(sampleCount)")
        }
    }

    private var mainScreen: NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private var mainScreenFrame: CGRect {
        mainScreen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func startCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        calibration = nil
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
        calibration = nil
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

        guard let displayContext = makeDisplayContext() else {
            calibrationStatus = "calibration failed"
            calibrationDetail = "main screen metrics unavailable"
            appendLog("calibration failed: screen metrics unavailable")
            return
        }
        guard let calibrationSession = GazeCalibrationSession(display: displayContext.descriptor, mode: .full) else {
            calibrationStatus = "calibration failed"
            calibrationDetail = "core calibration session could not start"
            appendLog("calibration failed: session init returned nil")
            return
        }

        for (index, normalizedTarget) in CalibrationGrid.targets.enumerated() {
            if Task.isCancelled {
                calibrationStatus = "calibration cancelled"
                appendLog("calibration cancelled")
                return
            }

            calibrationStatus = "fixate \(index + 1)/\(CalibrationGrid.targets.count)"
            calibrationDetail = "waiting for stable samples"
            overlayModel.setCalibrationTarget(screenPoint(fromNormalized: normalizedTarget, in: displayContext.frame))
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

            guard let stableSamples = collector.stableSamples(minimumCount: 10) else {
                calibrationStatus = "insufficient data at point \(index + 1)"
                calibrationDetail = "need at least 10 confident samples"
                appendLog("calibration failed at point \(index + 1): insufficient stable samples")
                return
            }

            do {
                try calibrationSession.pushTarget(
                    u: Float(normalizedTarget.x),
                    v: Float(normalizedTarget.y),
                    targetID: UInt32(index)
                )
                for sample in stableSamples {
                    try calibrationSession.pushSample(sample, targetID: UInt32(index))
                }
            } catch {
                calibrationStatus = "calibration failed"
                calibrationDetail = error.localizedDescription
                appendLog("calibration failed at point \(index + 1): \(error.localizedDescription)")
                return
            }

            appendLog("captured calibration point \(index + 1)/\(CalibrationGrid.targets.count) with \(stableSamples.count) samples")
        }

        do {
            let solvedCalibration = try calibrationSession.solve()
            calibration = solvedCalibration
            calibrationStatus = "calibration complete"
            calibrationDetail = calibrationSummary(for: solvedCalibration)
            try calibrationPersistence.save(solvedCalibration)
            appendLog("calibration complete: \(calibrationSummary(for: solvedCalibration))")
            if solvedCalibration.rmsePixels > 120 {
                appendLog("warning: calibration rmse is high; check fixation stability and screen metrics")
            }
        } catch {
            calibrationStatus = "calibration fit failed"
            calibrationDetail = error.localizedDescription
            appendLog("calibration fit failed: \(error.localizedDescription)")
        }
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
                self.overlayModel.setTarget(self.screenPoint(
                    fromNormalized: CGPoint(x: normalizedX, y: normalizedY),
                    in: frame
                ))
            }
        }
        RunLoop.main.add(previewTimer!, forMode: .common)
    }

    private func collectCalibrationSampleIfNeeded(sample: ProviderSamplePayload) {
        guard var collector = calibrationCollector else {
            return
        }
        guard sample.confidence >= 0.45 else {
            return
        }

        let now = CACurrentMediaTime()
        guard now >= collector.collectionStart, now <= collector.collectionEnd else {
            return
        }

        collector.samples.append(sample)
        calibrationCollector = collector
        calibrationStatus = "fixate \(collector.stepIndex + 1)/\(CalibrationGrid.targets.count)"
        calibrationDetail = "\(collector.samples.count) stable samples"
    }

    private func mapToScreen(sample: ProviderSamplePayload) -> MappedPoint? {
        guard let displayContext = makeDisplayContext() else {
            updateRuntimeStatus("screen metrics unavailable")
            return nil
        }

        if let calibration {
            do {
                let solvedPoint = try calibration.solvePoint(sample: sample, display: displayContext.descriptor)
                updateRuntimeStatus("core solve active")
                let normalized = CGPoint(
                    x: clamp(CGFloat(solvedPoint.u), min: 0.0, max: 1.0),
                    y: clamp(CGFloat(solvedPoint.v), min: 0.0, max: 1.0)
                )
                let point = screenPoint(fromNormalized: normalized, in: displayContext.frame)
                return MappedPoint(
                    point: point,
                    debugDescription: String(
                        format: "%.0f, %.0f | u=%.3f v=%.3f%@",
                        point.x,
                        point.y,
                        solvedPoint.u,
                        solvedPoint.v,
                        solvedPoint.insideScreen ? "" : " edge"
                    )
                )
            } catch {
                updateRuntimeStatus("core solve fallback: \(error.localizedDescription)")
            }
        } else {
            updateRuntimeStatus("uncalibrated heuristic")
        }

        let fallbackPoint = uncalibratedMapper.map(sample: sample, in: displayContext.frame)
        return MappedPoint(
            point: fallbackPoint,
            debugDescription: String(format: "%.0f, %.0f | heuristic", fallbackPoint.x, fallbackPoint.y)
        )
    }

    private func screenPoint(fromNormalized normalizedPoint: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: frame.minX + normalizedPoint.x * frame.width,
            y: frame.maxY - normalizedPoint.y * frame.height
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
            guard let savedCalibration = try calibrationPersistence.load() else {
                return
            }
            calibration = savedCalibration
            calibrationStatus = "calibration restored"
            calibrationDetail = calibrationSummary(for: savedCalibration)
            appendLog("restored saved calibration: \(calibrationSummary(for: savedCalibration))")
        } catch {
            calibrationStatus = "uncalibrated"
            calibrationDetail = "saved calibration could not be loaded"
            appendLog("failed to restore calibration: \(error.localizedDescription)")
        }
    }

    private func makeDisplayContext() -> DisplayContext? {
        guard let screen = mainScreen else {
            return nil
        }
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let displayID = CGDirectDisplayID(truncating: screenNumber)
        let widthPixels = UInt32(CGDisplayPixelsWide(displayID))
        let heightPixels = UInt32(CGDisplayPixelsHigh(displayID))
        guard widthPixels > 0, heightPixels > 0 else {
            return nil
        }

        var physicalSize = CGDisplayScreenSize(displayID)
        if physicalSize.width <= 0 || physicalSize.height <= 0 {
            let fallbackMMPerPixel = CGFloat(25.4 / 110.0)
            physicalSize = CGSize(
                width: CGFloat(widthPixels) * fallbackMMPerPixel,
                height: CGFloat(heightPixels) * fallbackMMPerPixel
            )
        }

        return DisplayContext(
            frame: screen.frame,
            descriptor: GazeDisplayDescriptor(
                screenWidthMM: Float(physicalSize.width),
                screenHeightMM: Float(physicalSize.height),
                widthPixels: widthPixels,
                heightPixels: heightPixels
            )
        )
    }

    private func calibrationSummary(for calibration: GazeCalibration) -> String {
        String(
            format: "rmse %.1f px, median %.1f px, samples %u",
            calibration.rmsePixels,
            calibration.medianErrorPixels,
            calibration.sampleCount
        )
    }

    private func updateRuntimeStatus(_ status: String) {
        guard status != lastRuntimeStatus else {
            return
        }
        lastRuntimeStatus = status
        appendLog(status)
    }
}

private struct DisplayContext {
    let frame: CGRect
    let descriptor: GazeDisplayDescriptor
}

private struct MappedPoint {
    let point: CGPoint
    let debugDescription: String
}

private struct GazeScreenMapper {
    private let horizontalGain: CGFloat = 6.4
    private let verticalGain: CGFloat = 7.2
    private let verticalBias: CGFloat = 0.01

    func map(sample: ProviderSamplePayload, in frame: CGRect) -> CGPoint {
        let rawX = CGFloat(sample.lookAtPointFM[0])
        let rawY = CGFloat(sample.lookAtPointFM[1])

        let normalizedX = clamp(0.5 + rawX * horizontalGain, min: 0.0, max: 1.0)
        let normalizedY = clamp(0.5 - (rawY - verticalBias) * verticalGain, min: 0.0, max: 1.0)

        return CGPoint(
            x: frame.minX + normalizedX * frame.width,
            y: frame.maxY - normalizedY * frame.height
        )
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }
}
