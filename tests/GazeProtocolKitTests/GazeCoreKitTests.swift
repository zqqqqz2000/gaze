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

    private func makeSample(
        origin: (Float, Float, Float),
        direction: (Float, Float, Float)
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
            headRotPFQ: [0, 0, 0, 1],
            headPosPM: [0, 0, 0],
            lookAtPointFM: [0, 0, 0],
            confidence: 1,
            faceDistanceM: 0.55
        )
    }
}
