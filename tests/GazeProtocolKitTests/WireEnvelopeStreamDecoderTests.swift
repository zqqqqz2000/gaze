import XCTest
@testable import GazeProtocolKit

final class WireEnvelopeStreamDecoderTests: XCTestCase {
    func testDecoderWaitsForFullFrame() throws {
        let frame = WireEnvelope(channel: .data, kind: 1, payload: Data([1, 2, 3, 4])).encode()
        var decoder = WireEnvelopeStreamDecoder()

        decoder.append(frame.prefix(7))
        XCTAssertNil(try decoder.nextEnvelope())

        decoder.append(frame.dropFirst(7))
        XCTAssertEqual(try decoder.nextEnvelope(), WireEnvelope(channel: .data, kind: 1, payload: Data([1, 2, 3, 4])))
        XCTAssertNil(try decoder.nextEnvelope())
    }

    func testDecoderConsumesMultipleFramesFromSingleBuffer() throws {
        let frameA = WireEnvelope(channel: .data, kind: 1, payload: Data([9, 8, 7])).encode()
        let frameB = WireEnvelope(channel: .control, kind: 3, payload: Data([6, 5])).encode()
        var decoder = WireEnvelopeStreamDecoder()

        decoder.append(frameA + frameB)

        XCTAssertEqual(try decoder.nextEnvelope(), WireEnvelope(channel: .data, kind: 1, payload: Data([9, 8, 7])))
        XCTAssertEqual(try decoder.nextEnvelope(), WireEnvelope(channel: .control, kind: 3, payload: Data([6, 5])))
        XCTAssertNil(try decoder.nextEnvelope())
    }

    func testDecoderRejectsBadMagic() {
        var decoder = WireEnvelopeStreamDecoder()
        decoder.append(Data([0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))

        XCTAssertThrowsError(try decoder.nextEnvelope()) { error in
            XCTAssertEqual(error as? WireProtocolError, .badMagic)
        }
    }
}
