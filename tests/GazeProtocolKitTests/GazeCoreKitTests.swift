import XCTest
import GazeCoreKit
import GazeProtocolKit

final class GazeCoreKitTests: XCTestCase {
    func testCalibrationSessionSolveAndSerializeRoundTrip() throws {
        let display = GazeDisplayDescriptor(
            screenWidthMM: 600,
            screenHeightMM: 340,
            widthPixels: 1920,
            heightPixels: 1080
        )
        let session = try XCTUnwrap(GazeCalibrationSession(display: display, mode: .full))
        let targets: [(Float, Float)] = [
            (0.2, 0.2), (0.5, 0.2), (0.8, 0.2),
            (0.2, 0.5), (0.5, 0.5), (0.8, 0.5),
            (0.2, 0.8), (0.5, 0.8), (0.8, 0.8),
        ]

        for (index, target) in targets.enumerated() {
            try session.pushTarget(u: target.0, v: target.1, targetID: UInt32(index))
            let xM = (target.0 - 0.5) * 0.6
            let yM = (0.5 - target.1) * 0.34
            try session.pushSample(
                makeSample(origin: (0, 0, 0), direction: (-xM, yM, 0.6)),
                targetID: UInt32(index)
            )
        }

        let calibration = try session.solve()
        XCTAssertLessThan(calibration.rmsePixels, 80)

        let centerPoint = try calibration.solvePoint(
            sample: makeSample(origin: (0, 0, 0), direction: (0, 0, 0.6)),
            display: display
        )
        XCTAssertEqual(centerPoint.u, 0.5, accuracy: 0.08)
        XCTAssertEqual(centerPoint.v, 0.5, accuracy: 0.08)

        let blob = try calibration.serializedData()
        let decoded = try GazeCalibration(serializedData: blob)
        let decodedCenterPoint = try decoded.solvePoint(
            sample: makeSample(origin: (0, 0, 0), direction: (0, 0, 0.6)),
            display: display
        )
        XCTAssertEqual(decodedCenterPoint.u, centerPoint.u, accuracy: 0.0001)
        XCTAssertEqual(decodedCenterPoint.v, centerPoint.v, accuracy: 0.0001)
    }

    func testCalibrationWorksAfterHeadRotation() throws {
        let display = GazeDisplayDescriptor(
            screenWidthMM: 600, screenHeightMM: 340,
            widthPixels: 1920, heightPixels: 1080
        )
        let session = try XCTUnwrap(GazeCalibrationSession(display: display, mode: .full))

        let targets: [(Float, Float)] = [
            (0.15, 0.15), (0.50, 0.15), (0.85, 0.15),
            (0.15, 0.50), (0.50, 0.50), (0.85, 0.50),
            (0.15, 0.85), (0.50, 0.85), (0.85, 0.85),
        ]
        let yawBias: Float = 0.04
        let pitchBias: Float = -0.025

        for (index, target) in targets.enumerated() {
            try session.pushTarget(u: target.0, v: target.1, targetID: UInt32(index))
            let dir = biasedGaze(
                eye: (0, 0, 0), targetU: target.0, targetV: target.1,
                yawBias: yawBias, pitchBias: pitchBias, headYaw: 0
            )
            try session.pushSample(
                makeSampleWithHeadYaw(origin: (0, 0, 0), direction: dir, headYaw: 0),
                targetID: UInt32(index)
            )
        }

        let calibration = try session.solve()

        let identityDir = biasedGaze(
            eye: (0, 0, 0), targetU: 0.5, targetV: 0.5,
            yawBias: yawBias, pitchBias: pitchBias, headYaw: 0
        )
        let identityPoint = try calibration.solvePoint(
            sample: makeSampleWithHeadYaw(origin: (0, 0, 0), direction: identityDir, headYaw: 0),
            display: display
        )
        XCTAssertEqual(identityPoint.u, 0.5, accuracy: 0.06)
        XCTAssertEqual(identityPoint.v, 0.5, accuracy: 0.06)

        let testYaw: Float = 0.4363
        let testEye: (Float, Float, Float) = (0.08, 0.01, 0.02)
        let rotatedDir = biasedGaze(
            eye: testEye, targetU: 0.5, targetV: 0.5,
            yawBias: yawBias, pitchBias: pitchBias, headYaw: testYaw
        )
        let rotatedPoint = try calibration.solvePoint(
            sample: makeSampleWithHeadYaw(origin: testEye, direction: rotatedDir, headYaw: testYaw),
            display: display
        )
        XCTAssertEqual(rotatedPoint.u, 0.5, accuracy: 0.06)
        XCTAssertEqual(rotatedPoint.v, 0.5, accuracy: 0.06)
    }

    func testCalibrationWithMixedHeadPoses() throws {
        let display = GazeDisplayDescriptor(
            screenWidthMM: 600, screenHeightMM: 340,
            widthPixels: 1920, heightPixels: 1080
        )
        let session = try XCTUnwrap(GazeCalibrationSession(display: display, mode: .full))

        let targets: [(Float, Float)] = [
            (0.15, 0.15), (0.50, 0.15), (0.85, 0.15),
            (0.15, 0.50), (0.50, 0.50), (0.85, 0.50),
            (0.15, 0.85), (0.50, 0.85), (0.85, 0.85),
        ]
        let yawBias: Float = 0.035
        let pitchBias: Float = -0.02
        let headYaws: [Float] = [0.0, 0.15, -0.12, -0.2, 0.0, 0.25, 0.1, -0.15, 0.3]
        let eyeOffsets: [(Float, Float, Float)] = [
            (0, 0, 0), (0.03, 0, 0.01), (-0.02, 0.01, 0),
            (-0.05, 0, 0), (0, 0, 0), (0.06, 0.01, 0.01),
            (0.02, -0.01, 0), (-0.03, 0, 0.01), (0.08, 0, 0.02),
        ]

        for (index, target) in targets.enumerated() {
            try session.pushTarget(u: target.0, v: target.1, targetID: UInt32(index))
            let dir = biasedGaze(
                eye: eyeOffsets[index], targetU: target.0, targetV: target.1,
                yawBias: yawBias, pitchBias: pitchBias, headYaw: headYaws[index]
            )
            try session.pushSample(
                makeSampleWithHeadYaw(origin: eyeOffsets[index], direction: dir, headYaw: headYaws[index]),
                targetID: UInt32(index)
            )
        }

        let calibration = try session.solve()

        let testYaw: Float = 0.40
        let testEye: (Float, Float, Float) = (0.1, 0.0, 0.03)
        let dir = biasedGaze(
            eye: testEye, targetU: 0.5, targetV: 0.5,
            yawBias: yawBias, pitchBias: pitchBias, headYaw: testYaw
        )
        let point = try calibration.solvePoint(
            sample: makeSampleWithHeadYaw(origin: testEye, direction: dir, headYaw: testYaw),
            display: display
        )
        XCTAssertEqual(point.u, 0.5, accuracy: 0.06)
        XCTAssertEqual(point.v, 0.5, accuracy: 0.06)
    }

    func testHeadRotationMultipleTargets() throws {
        let display = GazeDisplayDescriptor(
            screenWidthMM: 600, screenHeightMM: 340,
            widthPixels: 1920, heightPixels: 1080
        )
        let session = try XCTUnwrap(GazeCalibrationSession(display: display, mode: .full))

        let targets: [(Float, Float)] = [
            (0.15, 0.15), (0.50, 0.15), (0.85, 0.15),
            (0.15, 0.50), (0.50, 0.50), (0.85, 0.50),
            (0.15, 0.85), (0.50, 0.85), (0.85, 0.85),
        ]
        let yawBias: Float = 0.06
        let pitchBias: Float = -0.04

        for (index, target) in targets.enumerated() {
            try session.pushTarget(u: target.0, v: target.1, targetID: UInt32(index))
            let dir = biasedGaze(
                eye: (0, 0, 0), targetU: target.0, targetV: target.1,
                yawBias: yawBias, pitchBias: pitchBias, headYaw: 0
            )
            try session.pushSample(
                makeSampleWithHeadYaw(origin: (0, 0, 0), direction: dir, headYaw: 0),
                targetID: UInt32(index)
            )
        }

        let calibration = try session.solve()

        let testYaw: Float = 0.5236
        let testEye: (Float, Float, Float) = (0.1, 0.02, 0.03)
        let probes: [(Float, Float)] = [
            (0.3, 0.3), (0.7, 0.3), (0.5, 0.5), (0.3, 0.7), (0.7, 0.7),
        ]

        for probe in probes {
            let dir = biasedGaze(
                eye: testEye, targetU: probe.0, targetV: probe.1,
                yawBias: yawBias, pitchBias: pitchBias, headYaw: testYaw
            )
            let point = try calibration.solvePoint(
                sample: makeSampleWithHeadYaw(origin: testEye, direction: dir, headYaw: testYaw),
                display: display
            )
            XCTAssertEqual(point.u, probe.0, accuracy: 0.07, "u for target (\(probe.0), \(probe.1))")
            XCTAssertEqual(point.v, probe.1, accuracy: 0.07, "v for target (\(probe.0), \(probe.1))")
        }
    }

    func testHeadTranslationLargeRange() throws {
        let display = GazeDisplayDescriptor(
            screenWidthMM: 600, screenHeightMM: 340,
            widthPixels: 1920, heightPixels: 1080
        )
        let session = try XCTUnwrap(GazeCalibrationSession(display: display, mode: .full))

        let targets: [(Float, Float)] = [
            (0.15, 0.15), (0.50, 0.15), (0.85, 0.15),
            (0.15, 0.50), (0.50, 0.50), (0.85, 0.50),
            (0.15, 0.85), (0.50, 0.85), (0.85, 0.85),
        ]
        let yawBias: Float = 0.045
        let pitchBias: Float = -0.03

        for (index, target) in targets.enumerated() {
            try session.pushTarget(u: target.0, v: target.1, targetID: UInt32(index))
            let dir = biasedGaze(
                eye: (0, 0, 0), targetU: target.0, targetV: target.1,
                yawBias: yawBias, pitchBias: pitchBias, headYaw: 0
            )
            try session.pushSample(
                makeSampleWithHeadYaw(origin: (0, 0, 0), direction: dir, headYaw: 0),
                targetID: UInt32(index)
            )
        }

        let calibration = try session.solve()

        let eyePositions: [(Float, Float, Float)] = [
            ( 0.20,  0.00,  0.00),
            (-0.18,  0.00,  0.00),
            ( 0.00,  0.15,  0.00),
            ( 0.00, -0.12,  0.00),
            ( 0.00,  0.00,  0.10),
            ( 0.00,  0.00, -0.08),
            ( 0.15,  0.10,  0.05),
            (-0.12, -0.08,  0.07),
            ( 0.18, -0.10, -0.06),
            (-0.20,  0.12,  0.09),
            ( 0.10,  0.14, -0.05),
            (-0.07, -0.15,  0.10),
        ]
        let probes: [(Float, Float)] = [
            (0.5, 0.5), (0.2, 0.2), (0.8, 0.8), (0.3, 0.7), (0.7, 0.3),
        ]

        for eye in eyePositions {
            let headYaw = atan2(eye.0, 0.6) * 0.3
            for probe in probes {
                let dir = biasedGaze(
                    eye: eye, targetU: probe.0, targetV: probe.1,
                    yawBias: yawBias, pitchBias: pitchBias, headYaw: headYaw
                )
                let point = try calibration.solvePoint(
                    sample: makeSampleWithHeadYaw(origin: eye, direction: dir, headYaw: headYaw),
                    display: display
                )
                XCTAssertEqual(point.u, probe.0, accuracy: 0.07,
                    "eye=(\(eye.0),\(eye.1),\(eye.2)) target=(\(probe.0),\(probe.1))")
                XCTAssertEqual(point.v, probe.1, accuracy: 0.07,
                    "eye=(\(eye.0),\(eye.1),\(eye.2)) target=(\(probe.0),\(probe.1))")
            }
        }
    }

    // MARK: - Helpers

    private func makeSample(
        origin: (Float, Float, Float),
        direction: (Float, Float, Float)
    ) -> ProviderSamplePayload {
        makeSampleWithHeadYaw(origin: origin, direction: direction, headYaw: 0)
    }

    private func makeSampleWithHeadYaw(
        origin: (Float, Float, Float),
        direction: (Float, Float, Float),
        headYaw: Float
    ) -> ProviderSamplePayload {
        ProviderSamplePayload(
            timestampNs: 0,
            trackingFlags: 1,
            gazeOriginPM: [origin.0, origin.1, origin.2],
            gazeDirP: [direction.0, direction.1, direction.2],
            leftEyeOriginPM: [origin.0, origin.1, origin.2],
            leftEyeDirP: [direction.0, direction.1, direction.2],
            rightEyeOriginPM: [origin.0, origin.1, origin.2],
            rightEyeDirP: [direction.0, direction.1, direction.2],
            headRotPFQ: [0, sin(headYaw * 0.5), 0, cos(headYaw * 0.5)],
            headPosPM: [origin.0, origin.1, origin.2],
            lookAtPointFM: [0, 0, 0],
            confidence: 1,
            faceDistanceM: 0.55
        )
    }

    private func screenPointFront(u: Float, v: Float) -> (Float, Float, Float) {
        ((0.5 - u) * 0.6, (0.5 - v) * 0.34, 0.6)
    }

    private func rotX(_ v: (Float, Float, Float), angle: Float) -> (Float, Float, Float) {
        let c = cos(angle), s = sin(angle)
        return (v.0, c * v.1 - s * v.2, s * v.1 + c * v.2)
    }

    private func rotY(_ v: (Float, Float, Float), angle: Float) -> (Float, Float, Float) {
        let c = cos(angle), s = sin(angle)
        return (c * v.0 + s * v.2, v.1, -s * v.0 + c * v.2)
    }

    private func normalized(_ v: (Float, Float, Float)) -> (Float, Float, Float) {
        let l = sqrt(v.0 * v.0 + v.1 * v.1 + v.2 * v.2)
        return (v.0 / l, v.1 / l, v.2 / l)
    }

    private func biasedGaze(
        eye: (Float, Float, Float),
        targetU: Float, targetV: Float,
        yawBias: Float, pitchBias: Float,
        headYaw: Float
    ) -> (Float, Float, Float) {
        let sp = screenPointFront(u: targetU, v: targetV)
        let d = normalized((sp.0 - eye.0, sp.1 - eye.1, sp.2 - eye.2))
        var df = rotY(d, angle: -headYaw)
        df = rotY(df, angle: -yawBias)
        df = rotX(df, angle: -pitchBias)
        return normalized(rotY(df, angle: headYaw))
    }
}
