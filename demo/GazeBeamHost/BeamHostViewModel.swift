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
    @Published var usbBridgeStatus = "checking iproxy"
    @Published var usbClientStatus = "idle"
    @Published var overlayEnabled = true {
        didSet {
            overlayController.setVisible(overlayEnabled)
            appendLog(overlayEnabled ? "overlay enabled" : "overlay hidden")
        }
    }
    @Published var beamSize: Double = 88 {
        didSet {
            overlayModel.baseRadius = CGFloat(beamSize)
        }
    }
    @Published var calibrationStatus = "uncalibrated"
    @Published var calibrationDetail = "run 9-point host calibration"
    @Published var activeGlassesMode: GazeActiveState = .noGlasses {
        didSet { applyActiveGlassesMode(oldValue: oldValue) }
    }
    @Published var logLines: [String] = []
    @Published var logFilePath = HostFileLogger.shared.logFileURL.path

    let listenerPort: UInt16 = 9000
    let usbForwardedLocalPort: UInt16 = 9101
    let usbDevicePort: UInt16 = 9100
    var hasCalibration: Bool { calibration != nil }
    var isCalibrating: Bool { calibrationTask != nil }
    var isGlassesCalibration: Bool { currentCalibrationMode == .glasses }
    var glassesCalibrated: Bool { calibration?.hasGlasses == true }
    var isUSBBridgeRunning: Bool { usbBridge.isRunning }
    var canStartUSBBridge: Bool { USBMuxBridge.resolveExecutablePath() != nil }

    private let overlayModel = BeamOverlayModel()
    private lazy var overlayController = BeamOverlayWindowController(model: overlayModel)
    private let sampleServer = ProviderSampleServer()
    private let usbBridge = USBMuxBridge()
    private let fileLogger = HostFileLogger.shared
    private let uncalibratedMapper = GazeScreenMapper()
    private var didStart = false
    private var calibration: GazeCalibration? {
        didSet { syncActiveGlassesModeFromCalibration() }
    }
    private var calibrationCollector: CalibrationCollector?
    private var calibrationTask: Task<Void, Never>?
    private var currentCalibrationMode: GazeCalibrationMode?
    private let calibrationPersistence = CalibrationPersistence()
    private var lastRuntimeStatus = "idle"
    private var usbClient: ProviderSampleClient?
    private var usbReconnectTask: Task<Void, Never>?
    private var shouldMaintainUSBConnection = false

    init() {
        overlayModel.baseRadius = CGFloat(beamSize)

        sampleServer.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }

        usbBridge.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleUSBBridgeEvent(event)
            }
        }
    }

    func startIfNeeded() {
        guard !didStart else {
            return
        }
        didStart = true
        localAddresses = LocalIPAddressProvider.ipv4Addresses()
        refreshUSBAvailability()
        overlayController.show()
        appendLog("host log file: \(logFilePath)")

        do {
            try sampleServer.start(port: listenerPort)
            serverStatus = "listening"
            appendLog("listening on \(listenerPort)")
        } catch {
            serverStatus = "failed"
            appendLog("listener failed: \(error.localizedDescription)")
        }

        restoreCalibrationIfAvailable()
    }

    func startUSBBridge() {
        usbReconnectTask?.cancel()
        stopUSBClient()
        shouldMaintainUSBConnection = true

        do {
            try usbBridge.start(localPort: usbForwardedLocalPort, devicePort: usbDevicePort)
            usbBridgeStatus = "forwarding localhost:\(usbForwardedLocalPort) -> device:\(usbDevicePort)"
            appendLog("USB bridge started: localhost:\(usbForwardedLocalPort) -> device:\(usbDevicePort)")
            connectUSBClient()
        } catch {
            shouldMaintainUSBConnection = false
            usbBridgeStatus = "failed"
            usbClientStatus = error.localizedDescription
            appendLog("USB bridge failed: \(error.localizedDescription)")
        }
    }

    func stopUSBBridge() {
        shouldMaintainUSBConnection = false
        usbReconnectTask?.cancel()
        usbReconnectTask = nil
        stopUSBClient()
        usbBridge.stop()
        usbClientStatus = "idle"
        usbBridgeStatus = canStartUSBBridge ? "stopped" : "iproxy not installed"
        appendLog("USB bridge stopped")
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

    private func connectUSBClient() {
        guard shouldMaintainUSBConnection else {
            return
        }
        stopUSBClient()
        appendLog("starting USB sample client to 127.0.0.1:\(usbForwardedLocalPort)")

        let client = ProviderSampleClient(host: "127.0.0.1", port: usbForwardedLocalPort)
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleUSBClientEvent(event)
            }
        }
        usbClient = client
        client.start()
    }

    private func stopUSBClient() {
        usbClient?.stop()
        usbClient = nil
    }

    private func scheduleUSBReconnect() {
        guard shouldMaintainUSBConnection else {
            return
        }
        usbReconnectTask?.cancel()
        usbReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            self.connectUSBClient()
        }
    }

    private func handleUSBBridgeEvent(_ event: USBMuxBridge.Event) {
        switch event {
        case .started(let executablePath):
            appendLog("iproxy launched from \(executablePath)")
        case .output(let line):
            appendLog("iproxy: \(line)")
        case .stopped(let status):
            shouldMaintainUSBConnection = false
            stopUSBClient()
            usbReconnectTask?.cancel()
            usbReconnectTask = nil
            usbBridgeStatus = "iproxy exited with \(status)"
            usbClientStatus = status == 0 ? "idle" : "iproxy exited with \(status)"
            appendLog("USB bridge exited with status \(status)")
        }
    }

    private func handleUSBClientEvent(_ event: ProviderSampleClient.Event) {
        switch event {
        case .stateChanged(let message):
            appendLog("USB sample client: \(message)")
        case .connecting(let endpoint):
            usbClientStatus = "connecting to \(endpoint)"
        case .connected(let endpoint):
            usbClientStatus = "connected to \(endpoint)"
            appendLog("USB sample client connected: \(endpoint)")
        case .connectionFailed(let message):
            usbClientStatus = "waiting for iPhone USB stream"
            appendLog("USB sample client connect failed: \(message)")
            scheduleUSBReconnect()
        case .disconnected(let endpoint):
            usbClientStatus = shouldMaintainUSBConnection ? "waiting for iPhone USB stream" : "idle"
            appendLog("USB sample client disconnected: \(endpoint)")
            scheduleUSBReconnect()
        case .receivedSample(let sample):
            consume(sample: sample)
        }
    }

    private func refreshUSBAvailability() {
        if usbBridge.isRunning {
            usbBridgeStatus = "forwarding localhost:\(usbForwardedLocalPort) -> device:\(usbDevicePort)"
        } else if USBMuxBridge.resolveExecutablePath() != nil {
            usbBridgeStatus = "ready on localhost:\(usbForwardedLocalPort)"
        } else {
            usbBridgeStatus = "iproxy not installed"
        }
    }

    private func consume(sample: ProviderSamplePayload) {
        sampleCount += 1
        confidenceText = String(format: "%.2f", sample.confidence)
        collectCalibrationSampleIfNeeded(sample: sample)

        guard let mappedPoint = mapToScreen(sample: sample) else {
            pointText = "-"
            overlayModel.clearTarget()
            return
        }

        pointText = mappedPoint.debugDescription

        if sample.confidence >= 0.35 && sample.trackingFlags == 1 {
            let now = CACurrentMediaTime()
            if now - lastFilteredTime > 0.5 {
                gazeFilterX.reset()
                gazeFilterY.reset()
            }
            let smoothX = gazeFilterX.filter(value: Double(mappedPoint.point.x), timestamp: now)
            let smoothY = gazeFilterY.filter(value: Double(mappedPoint.point.y), timestamp: now)
            lastFilteredTime = now
            overlayModel.setTarget(CGPoint(x: smoothX, y: smoothY))
        } else {
            overlayModel.clearTarget()
        }

        if sampleCount == 1 {
            appendLog("first streamed sample received")
        }
        if sampleCount == 1 || sampleCount.isMultiple(of: 300) {
            logPeriodicSampleDiagnostic(sample: sample, mapped: mappedPoint)
        }
        logDiagnosticSampleIfActive(sample: sample, mapped: mappedPoint)
        detectPositionJump(mappedPoint.point)
    }

    private var lastLoggedPoint: CGPoint?
    private var calibrationMeanFaceDistance: Float?
    private let gazeFilterX = OneEuroFilter(minCutoff: 1.5, beta: 0.5, dCutoff: 1.0)
    private let gazeFilterY = OneEuroFilter(minCutoff: 1.5, beta: 0.5, dCutoff: 1.0)
    private var lastFilteredTime: CFTimeInterval = 0
    private var diagStartTime: CFTimeInterval = 0
    private var diagEndTime: CFTimeInterval = 0
    private var lastDiagLogTime: CFTimeInterval = 0

    private func logDiagnosticSampleIfActive(sample: ProviderSamplePayload, mapped: MappedPoint) {
        let now = CACurrentMediaTime()
        guard diagEndTime > 0 else { return }
        if now >= diagEndTime {
            appendLog("=== HEAD-SWEEP DIAGNOSTIC END ===")
            diagEndTime = 0
            return
        }
        guard now - lastDiagLogTime >= 0.5 else { return }
        lastDiagLogTime = now
        let h = sample.headPosPM
        let r = sample.headRotPFQ
        appendLog("DIAG t=\(String(format: "%.1f", now - diagStartTime))s "
            + "hPos=(\(h.map { String(format: "%.3f", $0) }.joined(separator: ","))) "
            + "hRot=(\(r.map { String(format: "%.3f", $0) }.joined(separator: ","))) "
            + "-> \(mapped.debugDescription) "
            + "conf=\(String(format: "%.2f", sample.confidence)) "
            + "fd=\(String(format: "%.3f", sample.faceDistanceM))m")
    }

    private func logPeriodicSampleDiagnostic(sample: ProviderSamplePayload, mapped: MappedPoint) {
        let o = sample.gazeOriginPM
        let d = sample.gazeDirP
        let h = sample.headPosPM
        let r = sample.headRotPFQ
        appendLog("sample#\(sampleCount): "
            + "origin=(\(o.map { String(format: "%.4f", $0) }.joined(separator: ","))) "
            + "dir=(\(d.map { String(format: "%.4f", $0) }.joined(separator: ","))) "
            + "conf=\(String(format: "%.2f", sample.confidence)) "
            + "fd=\(String(format: "%.3f", sample.faceDistanceM))m "
            + "flags=\(sample.trackingFlags)")
        appendLog("  headPos=(\(h.map { String(format: "%.4f", $0) }.joined(separator: ","))) "
            + "headRot=(\(r.map { String(format: "%.4f", $0) }.joined(separator: ","))) "
            + "-> \(mapped.debugDescription)")

        if let calFD = calibrationMeanFaceDistance {
            let drift = abs(sample.faceDistanceM - calFD)
            if drift > 0.15 {
                appendLog("WARNING: faceDistance drifted \(String(format: "%.0f", drift * 100))cm from calibration "
                    + "(cal=\(String(format: "%.3f", calFD))m now=\(String(format: "%.3f", sample.faceDistanceM))m)")
            }
        }
    }

    private func detectPositionJump(_ point: CGPoint) {
        defer { lastLoggedPoint = point }
        guard let prev = lastLoggedPoint else { return }
        let jump = hypot(point.x - prev.x, point.y - prev.y)
        if jump > 400 {
            appendLog("WARNING: position jump \(String(format: "%.0f", jump))px "
                + "(\(String(format: "%.0f", prev.x)),\(String(format: "%.0f", prev.y)))"
                + "->(\(String(format: "%.0f", point.x)),\(String(format: "%.0f", point.y)))")
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
        gazeFilterX.reset()
        gazeFilterY.reset()
        calibrationStatus = "starting calibration"
        calibrationDetail = "hold gaze on each target; move head slightly between points"
        overlayEnabled = true
        currentCalibrationMode = .full

        calibrationTask = Task { @MainActor [weak self] in
            await self?.runCalibration(mode: .full)
        }
    }

    func startGlassesCalibration() {
        guard let baseline = calibration, !isCalibrating else {
            appendLog("glasses calibration skipped: no bare-eye baseline or already running")
            return
        }
        calibrationTask?.cancel()
        calibrationTask = nil
        gazeFilterX.reset()
        gazeFilterY.reset()
        calibrationStatus = "starting glasses calibration"
        calibrationDetail = "put glasses on; look at each dot while gently turning your head"
        overlayEnabled = true
        currentCalibrationMode = .glasses
        appendLog("glasses calibration requested (baseline rmse=\(String(format: "%.2f", baseline.rmsePixels))px)")

        calibrationTask = Task { @MainActor [weak self] in
            await self?.runCalibration(mode: .glasses)
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

    private func runCalibration(mode: GazeCalibrationMode) async {
        let bannerTag = mode == .glasses ? "GLASSES CALIBRATION" : "CALIBRATION"
        appendLog("=== \(bannerTag) SESSION BEGIN ===")
        defer {
            calibrationCollector = nil
            overlayModel.setCalibrationTarget(nil)
            calibrationTask = nil
            currentCalibrationMode = nil
        }

        guard let displayContext = makeDisplayContext() else {
            calibrationStatus = "calibration failed"
            calibrationDetail = "main screen metrics unavailable"
            appendLog("calibration failed: screen metrics unavailable")
            return
        }

        let desc = displayContext.descriptor
        appendLog("display: \(desc.widthPixels)x\(desc.heightPixels) px, "
            + "\(String(format: "%.1f", desc.screenWidthMM))x\(String(format: "%.1f", desc.screenHeightMM)) mm, "
            + "frame=\(displayContext.frame)")

        let calibrationSession: GazeCalibrationSession
        switch mode {
        case .glasses:
            guard let baseline = calibration else {
                calibrationStatus = "glasses calibration failed"
                calibrationDetail = "bare-eye baseline missing; run standard calibration first"
                appendLog("glasses calibration aborted: no baseline calibration available")
                return
            }
            guard let session = GazeCalibrationSession(display: desc, glassesBaseline: baseline) else {
                calibrationStatus = "glasses calibration failed"
                calibrationDetail = "core glasses session could not start"
                appendLog("glasses calibration failed: session init returned nil")
                return
            }
            calibrationSession = session
        default:
            guard let session = GazeCalibrationSession(display: desc, mode: mode) else {
                calibrationStatus = "calibration failed"
                calibrationDetail = "core calibration session could not start"
                appendLog("calibration failed: session init returned nil")
                return
            }
            calibrationSession = session
        }

        var pointDigests: [CalibrationPointDigest] = []

        for (index, normalizedTarget) in CalibrationGrid.targets.enumerated() {
            if Task.isCancelled {
                calibrationStatus = "calibration cancelled"
                appendLog("calibration cancelled at point \(index + 1)")
                return
            }

            let screenPt = screenPoint(fromNormalized: normalizedTarget, in: displayContext.frame)
            calibrationStatus = "fixate \(index + 1)/\(CalibrationGrid.targets.count)"
            calibrationDetail = "waiting for stable samples"
            overlayModel.setCalibrationTarget(screenPt)
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

            let totalCollected = collector.samples.count
            guard let stableSamples = collector.stableSamples(minimumCount: 10) else {
                calibrationStatus = "insufficient data at point \(index + 1)"
                calibrationDetail = "need at least 10 confident samples"
                appendLog("calibration FAILED at point \(index + 1): "
                    + "collected=\(totalCollected), need>=10 stable, "
                    + "target=(u=\(String(format: "%.2f", normalizedTarget.x)), v=\(String(format: "%.2f", normalizedTarget.y)))")
                return
            }

            let stats = sampleStatistics(stableSamples)
            let digest = CalibrationPointDigest(
                index: index,
                targetU: Double(normalizedTarget.x),
                targetV: Double(normalizedTarget.y),
                screenPt: screenPt,
                totalCollected: totalCollected,
                stableCount: stableSamples.count,
                meanOrigin: stats.meanOrigin,
                meanDirection: stats.meanDirection,
                meanHeadPos: stats.meanHeadPos,
                meanHeadRot: stats.meanHeadRot,
                meanConfidence: stats.meanConfidence,
                meanFaceDistance: stats.meanFaceDistance,
                stdevOrigin: stats.stdevOrigin
            )
            pointDigests.append(digest)

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
                appendLog("calibration FAILED at point \(index + 1): \(error.localizedDescription)")
                return
            }

            appendLog("point \(index + 1)/\(CalibrationGrid.targets.count): "
                + "target=(u=\(String(format: "%.2f", normalizedTarget.x)), v=\(String(format: "%.2f", normalizedTarget.y))) "
                + "screen=(\(String(format: "%.0f", screenPt.x)), \(String(format: "%.0f", screenPt.y))) "
                + "collected=\(totalCollected) stable=\(stableSamples.count) "
                + "meanConf=\(String(format: "%.3f", stats.meanConfidence)) "
                + "faceDist=\(String(format: "%.3f", stats.meanFaceDistance))m")
            appendLog("  origin=(\(stats.meanOrigin.map { String(format: "%.4f", $0) }.joined(separator: ", "))) "
                + "stdev=(\(stats.stdevOrigin.map { String(format: "%.5f", $0) }.joined(separator: ", ")))")
            appendLog("  dir=(\(stats.meanDirection.map { String(format: "%.4f", $0) }.joined(separator: ", "))) "
                + "headPos=(\(stats.meanHeadPos.map { String(format: "%.4f", $0) }.joined(separator: ", "))) "
                + "headRot=(\(stats.meanHeadRot.map { String(format: "%.4f", $0) }.joined(separator: ", ")))")
        }

        logPointConsistency(pointDigests)

        do {
            let result = try calibrationSession.solveWithQualityCheck()
            let solvedCalibration = result.calibration

            appendLog("=== CALIBRATION RESULT ===")
            appendLog("rmse=\(String(format: "%.2f", solvedCalibration.rmsePixels)) px, "
                + "median=\(String(format: "%.2f", solvedCalibration.medianErrorPixels)) px, "
                + "samples=\(solvedCalibration.sampleCount)")
            let noGlasses = solvedCalibration.noGlassesAffine
            appendLog("bareEye.b: yaw=\(String(format: "%.5f", noGlasses.bYaw)) rad "
                + "(\(String(format: "%.2f", noGlasses.bYaw * 180 / .pi))°), "
                + "pitch=\(String(format: "%.5f", noGlasses.bPitch)) rad "
                + "(\(String(format: "%.2f", noGlasses.bPitch * 180 / .pi))°)")
            appendLog("bareEye.G=[[\(String(format: "%.4f", noGlasses.gYawYaw)), "
                + "\(String(format: "%.4f", noGlasses.gYawPitch))], "
                + "[\(String(format: "%.4f", noGlasses.gPitchYaw)), "
                + "\(String(format: "%.4f", noGlasses.gPitchPitch))]]")
            if solvedCalibration.hasGlasses {
                let g = solvedCalibration.glassesAffine
                appendLog("glasses.b: yaw=\(String(format: "%.5f", g.bYaw)) rad, "
                    + "pitch=\(String(format: "%.5f", g.bPitch)) rad")
                appendLog("glasses.G=[[\(String(format: "%.4f", g.gYawYaw)), "
                    + "\(String(format: "%.4f", g.gYawPitch))], "
                    + "[\(String(format: "%.4f", g.gPitchYaw)), "
                    + "\(String(format: "%.4f", g.gPitchPitch))]]")
            }
            appendLog("activeState=\(solvedCalibration.activeState == .glasses ? "glasses" : "no_glasses")")
            appendLog("screenInCal=\(String(format: "%.1f", solvedCalibration.screenWidthMM))x"
                + "\(String(format: "%.1f", solvedCalibration.screenHeightMM)) mm")

            let T = solvedCalibration.transformProviderFromScreen
            appendLog("T_provider_from_screen:")
            for row in 0..<4 {
                let cols = (0..<4).map { String(format: "%+.6f", T[row * 4 + $0]) }
                appendLog("  [\(cols.joined(separator: ", "))]")
            }

            let resU = solvedCalibration.residualU
            let resV = solvedCalibration.residualV
            appendLog("residualU=[\(resU.map { String(format: "%.6f", $0) }.joined(separator: ", "))]")
            appendLog("residualV=[\(resV.map { String(format: "%.6f", $0) }.joined(separator: ", "))]")

            logBackSolveValidation(
                calibration: solvedCalibration,
                displayContext: displayContext,
                pointDigests: pointDigests
            )

            let avgFD = pointDigests.reduce(Float(0)) { $0 + $1.meanFaceDistance } / max(1, Float(pointDigests.count))
            calibrationMeanFaceDistance = avgFD
            appendLog("calibration mean faceDistance=\(String(format: "%.3f", avgFD))m")

            if result.qualityAcceptable {
                calibration = solvedCalibration
                calibrationStatus = "calibration complete"
                calibrationDetail = calibrationSummary(for: solvedCalibration)
                try calibrationPersistence.save(solvedCalibration)
                diagStartTime = CACurrentMediaTime()
                diagEndTime = diagStartTime + 45
                lastDiagLogTime = 0
                appendLog("=== HEAD-SWEEP DIAGNOSTIC BEGIN (45s) ===")
                appendLog("Look at screen center → rotate head → move head")
            } else {
                calibration = nil
                calibrationStatus = "calibration quality too low"
                calibrationDetail = "RMSE \(String(format: "%.0f", solvedCalibration.rmsePixels))px — please retry with stable head and fixation"
                appendLog("⚠ CALIBRATION REJECTED: quality too low (RMSE=\(String(format: "%.1f", solvedCalibration.rmsePixels))px)")
            }

            if solvedCalibration.rmsePixels > 120 {
                appendLog("WARNING: high rmse; check fixation stability and screen metrics")
            }
            let absBias = max(abs(noGlasses.bYaw), abs(noGlasses.bPitch))
            if absBias > 0.15 {
                appendLog("WARNING: bias is unusually large (\(String(format: "%.1f", absBias * 180 / .pi))°); "
                    + "calibration may degrade with head movement. "
                    + "Try varying head pose slightly across calibration points.")
            }
            appendLog("=== CALIBRATION SESSION END ===")
        } catch {
            calibrationStatus = "calibration fit failed"
            calibrationDetail = error.localizedDescription
            appendLog("calibration fit FAILED: \(error.localizedDescription)")
            appendLog("=== CALIBRATION SESSION END (FAILED) ===")
        }
    }

    private struct SampleStatistics {
        let meanOrigin: [Float]
        let meanDirection: [Float]
        let meanHeadPos: [Float]
        let meanHeadRot: [Float]
        let meanConfidence: Float
        let meanFaceDistance: Float
        let stdevOrigin: [Float]
    }

    private func sampleStatistics(_ samples: [ProviderSamplePayload]) -> SampleStatistics {
        let n = Float(samples.count)
        guard n > 0 else {
            return SampleStatistics(
                meanOrigin: [0, 0, 0], meanDirection: [0, 0, 0],
                meanHeadPos: [0, 0, 0], meanHeadRot: [0, 0, 0, 0],
                meanConfidence: 0, meanFaceDistance: 0, stdevOrigin: [0, 0, 0]
            )
        }

        func mean3(_ kp: KeyPath<ProviderSamplePayload, [Float]>) -> [Float] {
            let sum = samples.reduce([Float](repeating: 0, count: 3)) { acc, s in
                let v = s[keyPath: kp]
                return zip(acc, v).map(+)
            }
            return sum.map { $0 / n }
        }

        func mean4(_ kp: KeyPath<ProviderSamplePayload, [Float]>) -> [Float] {
            let sum = samples.reduce([Float](repeating: 0, count: 4)) { acc, s in
                let v = s[keyPath: kp]
                return zip(acc, v).map(+)
            }
            return sum.map { $0 / n }
        }

        let mo = mean3(\.gazeOriginPM)
        let md = mean3(\.gazeDirP)
        let mh = mean3(\.headPosPM)
        let mr = mean4(\.headRotPFQ)
        let mc = samples.reduce(Float(0)) { $0 + $1.confidence } / n
        let mf = samples.reduce(Float(0)) { $0 + $1.faceDistanceM } / n

        var stdev = [Float](repeating: 0, count: 3)
        if n > 1 {
            for s in samples {
                for i in 0..<3 {
                    let diff = (i < s.gazeOriginPM.count ? s.gazeOriginPM[i] : 0) - mo[i]
                    stdev[i] += diff * diff
                }
            }
            stdev = stdev.map { sqrt($0 / (n - 1)) }
        }

        return SampleStatistics(
            meanOrigin: mo, meanDirection: md,
            meanHeadPos: mh, meanHeadRot: mr,
            meanConfidence: mc, meanFaceDistance: mf,
            stdevOrigin: stdev
        )
    }

    private func logPointConsistency(_ digests: [CalibrationPointDigest]) {
        guard digests.count >= 2 else { return }

        appendLog("--- consistency checks ---")

        let faceDists = digests.map(\.meanFaceDistance)
        let minFD = faceDists.min() ?? 0
        let maxFD = faceDists.max() ?? 0
        let fdRange = maxFD - minFD
        appendLog("faceDistance range: \(String(format: "%.3f", minFD))–\(String(format: "%.3f", maxFD)) m "
            + "(delta=\(String(format: "%.3f", fdRange))m)")
        if fdRange > 0.08 {
            appendLog("WARNING: face distance varied >8cm across calibration points; head may have moved")
        }

        var headPosDeltas = [Float](repeating: 0, count: 3)
        for i in 0..<3 {
            let vals = digests.map { $0.meanHeadPos[i] }
            headPosDeltas[i] = (vals.max() ?? 0) - (vals.min() ?? 0)
        }
        appendLog("headPos range: dx=\(String(format: "%.4f", headPosDeltas[0])) "
            + "dy=\(String(format: "%.4f", headPosDeltas[1])) "
            + "dz=\(String(format: "%.4f", headPosDeltas[2]))m")
        let maxDrift = headPosDeltas.max() ?? 0
        if maxDrift > 0.10 {
            appendLog("WARNING: head drifted >\(String(format: "%.0f", maxDrift * 100))cm during calibration")
        }

        var headRotDiversity: Float = 0
        for digest in digests {
            for other in digests where other.index != digest.index {
                var dotProd: Float = 0
                for i in 0..<4 {
                    dotProd += digest.meanHeadRot[i] * other.meanHeadRot[i]
                }
                let angle = 2.0 * acos(min(1.0, abs(dotProd)))
                headRotDiversity = max(headRotDiversity, angle)
            }
        }
        appendLog("headRot diversity: \(String(format: "%.2f", headRotDiversity * 180 / .pi))° "
            + "(\(String(format: "%.4f", headRotDiversity)) rad)")
        if headRotDiversity < 0.05 {
            appendLog("WARNING: head barely rotated during calibration; "
                + "bias correction will be weak. For best accuracy, "
                + "move head slightly between calibration points.")
        }

        let stableCounts = digests.map(\.stableCount)
        let minStable = stableCounts.min() ?? 0
        let maxStable = stableCounts.max() ?? 0
        appendLog("stable sample counts: min=\(minStable) max=\(maxStable)")
        if minStable < 15 {
            appendLog("WARNING: some points had fewer than 15 stable samples; tracking may be noisy")
        }

        let leftPoints = digests.filter { $0.targetU < 0.3 }
        let rightPoints = digests.filter { $0.targetU > 0.7 }
        if let leftAvg = leftPoints.isEmpty ? nil : leftPoints.map({ $0.meanDirection[0] }).reduce(0, +) / Float(leftPoints.count),
           let rightAvg = rightPoints.isEmpty ? nil : rightPoints.map({ $0.meanDirection[0] }).reduce(0, +) / Float(rightPoints.count) {
            if rightAvg <= leftAvg {
                appendLog("WARNING: gaze direction X does not increase left→right "
                    + "(left avg=\(String(format: "%.4f", leftAvg)), right avg=\(String(format: "%.4f", rightAvg)))")
            }
        }

        let topPoints = digests.filter { $0.targetV < 0.3 }
        let bottomPoints = digests.filter { $0.targetV > 0.7 }
        if let topAvg = topPoints.isEmpty ? nil : topPoints.map({ $0.meanDirection[1] }).reduce(0, +) / Float(topPoints.count),
           let bottomAvg = bottomPoints.isEmpty ? nil : bottomPoints.map({ $0.meanDirection[1] }).reduce(0, +) / Float(bottomPoints.count) {
            if bottomAvg >= topAvg {
                appendLog("WARNING: gaze direction Y does not decrease top→bottom "
                    + "(top avg=\(String(format: "%.4f", topAvg)), bottom avg=\(String(format: "%.4f", bottomAvg)))")
            }
        }

        appendLog("--- end consistency checks ---")
    }

    private func logBackSolveValidation(
        calibration: GazeCalibration,
        displayContext: DisplayContext,
        pointDigests: [CalibrationPointDigest]
    ) {
        appendLog("--- back-solve validation ---")
        var maxErrPx: Float = 0
        var worstPoint = 0

        for digest in pointDigests {
            let probe = ProviderSamplePayload(
                timestampNs: 0, trackingFlags: 1,
                gazeOriginPM: digest.meanOrigin,
                gazeDirP: digest.meanDirection,
                leftEyeOriginPM: digest.meanOrigin,
                leftEyeDirP: digest.meanDirection,
                rightEyeOriginPM: digest.meanOrigin,
                rightEyeDirP: digest.meanDirection,
                headRotPFQ: digest.meanHeadRot,
                headPosPM: digest.meanHeadPos,
                lookAtPointFM: [0, 0, 0],
                confidence: digest.meanConfidence,
                faceDistanceM: digest.meanFaceDistance
            )

            do {
                let solved = try calibration.solvePoint(sample: probe, display: displayContext.descriptor)
                let errU = solved.u - Float(digest.targetU)
                let errV = solved.v - Float(digest.targetV)
                let errPxX = errU * Float(displayContext.descriptor.widthPixels)
                let errPxY = errV * Float(displayContext.descriptor.heightPixels)
                let errPx = sqrt(errPxX * errPxX + errPxY * errPxY)

                if errPx > maxErrPx {
                    maxErrPx = errPx
                    worstPoint = digest.index + 1
                }

                let flag = errPx > 80 ? " ⚠" : ""
                appendLog("  pt\(digest.index + 1): target=(\(String(format: "%.2f", digest.targetU)), "
                    + "\(String(format: "%.2f", digest.targetV))) "
                    + "solved=(\(String(format: "%.3f", solved.u)), \(String(format: "%.3f", solved.v))) "
                    + "err=\(String(format: "%.1f", errPx))px\(flag)")
            } catch {
                appendLog("  pt\(digest.index + 1): back-solve FAILED: \(error.localizedDescription)")
            }
        }

        appendLog("worst point: \(worstPoint) (\(String(format: "%.1f", maxErrPx))px)")
        appendLog("--- end back-solve validation ---")
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

    private var solveFailureCount = 0

    private func mapToScreen(sample: ProviderSamplePayload) -> MappedPoint? {
        guard let displayContext = makeDisplayContext() else {
            updateRuntimeStatus("screen metrics unavailable")
            return nil
        }

        if let calibration {
            do {
                let solvedPoint = try calibration.solvePoint(sample: sample, display: displayContext.descriptor)
                updateRuntimeStatus("core solve active")
                solveFailureCount = 0

                let rawU = CGFloat(solvedPoint.u)
                let rawV = CGFloat(solvedPoint.v)
                let clampedU = clamp(rawU, min: 0.0, max: 1.0)
                let clampedV = clamp(rawV, min: 0.0, max: 1.0)

                let overshoot = max(
                    abs(rawU - clampedU) * displayContext.frame.width,
                    abs(rawV - clampedV) * displayContext.frame.height
                )
                if overshoot > 100 {
                    logThrottled(key: "clamp", interval: 2.0,
                        "WARNING: gaze clamped \(String(format: "%.0f", overshoot))px outside screen "
                        + "(raw u=\(String(format: "%.3f", rawU)) v=\(String(format: "%.3f", rawV)) "
                        + "dist=\(String(format: "%.3f", solvedPoint.distanceToScreenPlaneM))m "
                        + "angle=\(String(format: "%.1f", solvedPoint.rayPlaneAngleRad * 180 / .pi))°)")
                }

                let point = screenPoint(fromNormalized: CGPoint(x: clampedU, y: clampedV), in: displayContext.frame)
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
                solveFailureCount += 1
                if solveFailureCount == 1 || solveFailureCount == 10 || solveFailureCount.isMultiple(of: 100) {
                    let o = sample.gazeOriginPM
                    let d = sample.gazeDirP
                    appendLog("solve FAILED (#\(solveFailureCount)): \(error.localizedDescription) "
                        + "origin=(\(o.map { String(format: "%.4f", $0) }.joined(separator: ","))) "
                        + "dir=(\(d.map { String(format: "%.4f", $0) }.joined(separator: ","))) "
                        + "conf=\(String(format: "%.2f", sample.confidence)) "
                        + "flags=\(sample.trackingFlags)")
                }
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

    private var throttleTimestamps: [String: CFTimeInterval] = [:]

    private func logThrottled(key: String, interval: CFTimeInterval, _ message: String) {
        let now = CACurrentMediaTime()
        if let last = throttleTimestamps[key], now - last < interval { return }
        throttleTimestamps[key] = now
        appendLog(message)
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
        let timestamp = timestampString(for: Date())
        let line = "[\(timestamp)] \(message)"
        fileLogger.append(line)
        print(line)
        logLines.insert(line, at: 0)
        if logLines.count > 30 {
            logLines.removeLast(logLines.count - 30)
        }
    }

    private func timestampString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func restoreCalibrationIfAvailable() {
        do {
            guard let savedCalibration = try calibrationPersistence.load() else {
                return
            }
            calibration = savedCalibration
            gazeFilterX.reset()
            gazeFilterY.reset()
            calibrationStatus = "calibration restored"
            calibrationDetail = calibrationSummary(for: savedCalibration)
            appendLog("=== RESTORED CALIBRATION ===")
            logCalibrationParams(savedCalibration)
            appendLog("=== END RESTORED CALIBRATION ===")
        } catch {
            calibrationStatus = "uncalibrated"
            calibrationDetail = "saved calibration could not be loaded"
            appendLog("failed to restore calibration: \(error.localizedDescription)")
        }
    }

    private func applyActiveGlassesMode(oldValue: GazeActiveState) {
        guard var cal = calibration else { return }
        if activeGlassesMode == cal.activeState { return }
        if activeGlassesMode == .glasses, !cal.hasGlasses {
            appendLog("cannot activate glasses mode: no glasses calibration present")
            activeGlassesMode = oldValue
            return
        }
        do {
            try cal.setActiveState(activeGlassesMode)
            calibration = cal
            try calibrationPersistence.save(cal)
            appendLog("activeState updated to \(activeGlassesMode == .glasses ? "glasses" : "no_glasses")")
        } catch {
            appendLog("failed to switch active state: \(error.localizedDescription)")
            activeGlassesMode = oldValue
        }
    }

    private func syncActiveGlassesModeFromCalibration() {
        let desired = calibration?.activeState ?? .noGlasses
        if activeGlassesMode != desired {
            activeGlassesMode = desired
        }
    }

    private func logCalibrationParams(_ cal: GazeCalibration) {
        appendLog("rmse=\(String(format: "%.2f", cal.rmsePixels))px "
            + "median=\(String(format: "%.2f", cal.medianErrorPixels))px "
            + "samples=\(cal.sampleCount)")
        let noGlasses = cal.noGlassesAffine
        appendLog("bareEye.b: yaw=\(String(format: "%.5f", noGlasses.bYaw))rad "
            + "(\(String(format: "%.2f", noGlasses.bYaw * 180 / .pi))°) "
            + "pitch=\(String(format: "%.5f", noGlasses.bPitch))rad "
            + "(\(String(format: "%.2f", noGlasses.bPitch * 180 / .pi))°)")
        appendLog("bareEye.G=[[\(String(format: "%.4f", noGlasses.gYawYaw)),"
            + "\(String(format: "%.4f", noGlasses.gYawPitch))],"
            + "[\(String(format: "%.4f", noGlasses.gPitchYaw)),"
            + "\(String(format: "%.4f", noGlasses.gPitchPitch))]] "
            + "screen=\(String(format: "%.1f", cal.screenWidthMM))x\(String(format: "%.1f", cal.screenHeightMM))mm")
        if cal.hasGlasses {
            let g = cal.glassesAffine
            appendLog("glasses.G=[[\(String(format: "%.4f", g.gYawYaw)),"
                + "\(String(format: "%.4f", g.gYawPitch))],"
                + "[\(String(format: "%.4f", g.gPitchYaw)),"
                + "\(String(format: "%.4f", g.gPitchPitch))]] "
                + "b=(\(String(format: "%.5f", g.bYaw)), \(String(format: "%.5f", g.bPitch)))")
        }
        appendLog("activeState=\(cal.activeState == .glasses ? "glasses" : "no_glasses")")
        let T = cal.transformProviderFromScreen
        for row in 0..<4 {
            let cols = (0..<4).map { String(format: "%+.6f", T[row * 4 + $0]) }
            appendLog("  T[\(row)]=[\(cols.joined(separator: ", "))]")
        }

        if let ctx = makeDisplayContext() {
            let desc = ctx.descriptor
            if abs(cal.screenWidthMM - desc.screenWidthMM) > 1 || abs(cal.screenHeightMM - desc.screenHeightMM) > 1 {
                appendLog("WARNING: calibration screen size (\(String(format: "%.1f", cal.screenWidthMM))x"
                    + "\(String(format: "%.1f", cal.screenHeightMM))mm) differs from current display "
                    + "(\(String(format: "%.1f", desc.screenWidthMM))x\(String(format: "%.1f", desc.screenHeightMM))mm)")
            }
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

private struct CalibrationPointDigest {
    let index: Int
    let targetU: Double
    let targetV: Double
    let screenPt: CGPoint
    let totalCollected: Int
    let stableCount: Int
    let meanOrigin: [Float]
    let meanDirection: [Float]
    let meanHeadPos: [Float]
    let meanHeadRot: [Float]
    let meanConfidence: Float
    let meanFaceDistance: Float
    let stdevOrigin: [Float]
}

private struct MappedPoint {
    let point: CGPoint
    let debugDescription: String
}

private final class LowPassFilter {
    private(set) var value: Double = 0
    private(set) var initialized = false

    func apply(_ raw: Double, alpha: Double) -> Double {
        if initialized {
            value = alpha * raw + (1 - alpha) * value
        } else {
            value = raw
            initialized = true
        }
        return value
    }

    func reset() {
        initialized = false
        value = 0
    }
}

private final class OneEuroFilter {
    private let minCutoff: Double
    private let beta: Double
    private let dCutoff: Double
    private let x = LowPassFilter()
    private let dx = LowPassFilter()
    private var lastTime: Double?

    init(minCutoff: Double = 1.5, beta: Double = 0.5, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    func filter(value: Double, timestamp: Double) -> Double {
        let dt: Double
        if let last = lastTime {
            dt = max(timestamp - last, 1e-6)
        } else {
            dt = 1.0 / 60.0
        }
        lastTime = timestamp

        let dValue = x.initialized ? (value - x.value) / dt : 0.0
        let edValue = dx.apply(dValue, alpha: Self.smoothingAlpha(cutoff: dCutoff, dt: dt))
        let cutoff = minCutoff + beta * abs(edValue)
        return x.apply(value, alpha: Self.smoothingAlpha(cutoff: cutoff, dt: dt))
    }

    func reset() {
        x.reset()
        dx.reset()
        lastTime = nil
    }

    private static func smoothingAlpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
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
