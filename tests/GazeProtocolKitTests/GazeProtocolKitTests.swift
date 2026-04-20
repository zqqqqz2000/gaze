import Foundation
import XCTest
@testable import GazeProtocolKit

final class GazeProtocolKitTests: XCTestCase {
    func testProviderSampleBinaryRoundTrip() throws {
        let sample = ProviderSamplePayload(
            timestampNs: 42,
            trackingFlags: 1,
            gazeOriginPM: [0.1, 0.2, 0.3],
            gazeDirP: [0.0, 0.0, 1.0],
            leftEyeOriginPM: [0.1, 0.2, 0.3],
            leftEyeDirP: [0.0, 0.0, 1.0],
            rightEyeOriginPM: [0.1, 0.2, 0.3],
            rightEyeDirP: [0.0, 0.0, 1.0],
            headRotPFQ: [0.0, 0.0, 0.0, 1.0],
            headPosPM: [0.0, 0.0, 0.5],
            lookAtPointFM: [0.0, 0.0, 0.02],
            confidence: 0.9,
            faceDistanceM: 0.5
        )

        let encoded = BinarySampleCodec.encode(sample)
        let decoded = try BinarySampleCodec.decode(encoded)
        XCTAssertEqual(decoded, sample)
    }

    func testEnvelopeRoundTrip() throws {
        let payload = Data([1, 2, 3, 4, 5])
        let envelope = WireEnvelope(channel: .data, kind: 1, payload: payload)
        let decoded = try WireEnvelope.decode(envelope.encode())
        XCTAssertEqual(decoded, envelope)
    }
}
