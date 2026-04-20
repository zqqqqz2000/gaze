import XCTest
@testable import GazeProtocolKit

final class QuadraticCalibrationModelTests: XCTestCase {
    private let trainingSamples: [QuadraticCalibrationSample] = [
        (-0.18, -0.12), (0.0, -0.12), (0.18, -0.12),
        (-0.18, 0.0), (0.0, 0.0), (0.18, 0.0),
        (-0.18, 0.12), (0.0, 0.12), (0.18, 0.12),
    ].map { rawX, rawY in
        QuadraticCalibrationSample(
            rawX: rawX,
            rawY: rawY,
            targetX: 0.5 + 1.4 * rawX + 0.25 * rawY + 0.4 * rawX * rawY,
            targetY: 0.45 - 1.1 * rawY + 0.18 * rawX * rawX - 0.12 * rawY * rawY
        )
    }

    func testFitRecoversKnownQuadraticMapping() throws {
        let model = try XCTUnwrap(QuadraticCalibrationModel(samples: trainingSamples))
        let mapped = model.map(rawX: 0.11, rawY: -0.05)

        XCTAssertEqual(mapped.x, 0.5 + 1.4 * 0.11 + 0.25 * -0.05 + 0.4 * 0.11 * -0.05, accuracy: 1e-8)
        XCTAssertEqual(mapped.y, 0.45 - 1.1 * -0.05 + 0.18 * 0.11 * 0.11 - 0.12 * -0.05 * -0.05, accuracy: 1e-8)
    }

    func testFitRequiresEnoughSamples() {
        let samples = [
            QuadraticCalibrationSample(rawX: 0.0, rawY: 0.0, targetX: 0.5, targetY: 0.5),
            QuadraticCalibrationSample(rawX: 0.1, rawY: 0.1, targetX: 0.6, targetY: 0.4),
        ]

        XCTAssertNil(QuadraticCalibrationModel(samples: samples))
    }

    func testSerializedRoundTripPreservesMapping() throws {
        let model = try XCTUnwrap(QuadraticCalibrationModel(samples: trainingSamples))
        let data = try model.serializedData()
        let decoded = try QuadraticCalibrationModel(serializedData: data)

        let probe = decoded.map(rawX: 0.07, rawY: 0.03)
        XCTAssertEqual(probe.x, 0.60634, accuracy: 1e-8)
        XCTAssertEqual(probe.y, 0.417774, accuracy: 1e-8)
    }

    func testSerializedPayloadRejectsWrongCoefficientCount() throws {
        let payload = """
        {"version":1,"coefficientsX":[0,1,2],"coefficientsY":[0,1,2,3,4,5]}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try QuadraticCalibrationModel(serializedData: payload)) { error in
            XCTAssertEqual(error as? QuadraticCalibrationCodingError, .invalidCoefficientCount)
        }
    }

    func testRootMeanSquareErrorIsNearZeroForTrainingSamples() throws {
        let model = try XCTUnwrap(QuadraticCalibrationModel(samples: trainingSamples))
        XCTAssertEqual(model.rootMeanSquareError(samples: trainingSamples), 0, accuracy: 1e-10)
    }
}
