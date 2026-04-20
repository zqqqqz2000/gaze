import XCTest
import simd
@testable import GazeProtocolKit

final class ScreenPlaneCalibrationModelTests: XCTestCase {
    private let screenOrigin = SIMD3<Double>(0.22, -0.08, 0.62)
    private let screenAxisX = SIMD3<Double>(0.48, 0.02, 0.04)
    private let screenAxisY = SIMD3<Double>(0.01, -0.29, 0.03)

    func testFitRecoversScreenGeometryFromRaySamples() throws {
        let samples = makeTrainingSamples()
        let model = try XCTUnwrap(ScreenPlaneCalibrationModel(samples: samples))

        let probeOrigin = SIMD3<Double>(-0.03, 0.02, 0.01)
        let target = pointOnScreen(x: 0.63, y: 0.41)
        let probeDirection = simd_normalize(target - probeOrigin)
        let mapped = try XCTUnwrap(model.map(origin: probeOrigin, direction: probeDirection))

        XCTAssertEqual(mapped.x, 0.63, accuracy: 1e-8)
        XCTAssertEqual(mapped.y, 0.41, accuracy: 1e-8)
    }

    func testSerializedRoundTripPreservesProjection() throws {
        let model = try XCTUnwrap(ScreenPlaneCalibrationModel(samples: makeTrainingSamples()))
        let data = try model.serializedData()
        let decoded = try ScreenPlaneCalibrationModel(serializedData: data)

        let probeOrigin = SIMD3<Double>(0.04, -0.01, -0.02)
        let target = pointOnScreen(x: 0.21, y: 0.74)
        let probeDirection = simd_normalize(target - probeOrigin)
        let mapped = try XCTUnwrap(decoded.map(origin: probeOrigin, direction: probeDirection))

        XCTAssertEqual(mapped.x, 0.21, accuracy: 1e-8)
        XCTAssertEqual(mapped.y, 0.74, accuracy: 1e-8)
    }

    func testRootMeanSquareErrorIsNearZeroForTrainingSamples() throws {
        let samples = makeTrainingSamples()
        let model = try XCTUnwrap(ScreenPlaneCalibrationModel(samples: samples))
        XCTAssertEqual(model.rootMeanSquareError(samples: samples), 0, accuracy: 1e-10)
    }

    private func makeTrainingSamples() -> [ScreenPlaneCalibrationSample] {
        let grid: [(Double, Double, SIMD3<Double>)] = [
            (0.15, 0.18, SIMD3(-0.05, 0.02, -0.01)),
            (0.50, 0.18, SIMD3(0.00, 0.01, 0.00)),
            (0.85, 0.18, SIMD3(0.04, 0.03, -0.02)),
            (0.15, 0.50, SIMD3(-0.03, 0.00, 0.02)),
            (0.50, 0.50, SIMD3(0.02, -0.01, 0.01)),
            (0.85, 0.50, SIMD3(0.06, 0.00, -0.01)),
            (0.15, 0.82, SIMD3(-0.04, -0.02, 0.00)),
            (0.50, 0.82, SIMD3(0.00, -0.03, 0.01)),
            (0.85, 0.82, SIMD3(0.05, -0.02, -0.02)),
        ]

        return grid.map { x, y, origin in
            let target = pointOnScreen(x: x, y: y)
            return ScreenPlaneCalibrationSample(
                origin: origin,
                direction: simd_normalize(target - origin),
                targetX: x,
                targetY: y
            )
        }
    }

    private func pointOnScreen(x: Double, y: Double) -> SIMD3<Double> {
        screenOrigin + screenAxisX * x + screenAxisY * y
    }
}
