import Foundation

public struct WireEnvelopeStreamDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedBytes: Int {
        buffer.count
    }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func nextEnvelope() throws -> WireEnvelope? {
        guard buffer.count >= WireEnvelope.headerLength else {
            return nil
        }
        guard buffer.prefix(4) == WireEnvelope.magic else {
            throw WireProtocolError.badMagic
        }

        let version = try buffer.readLittleEndian(UInt16.self, at: 4)
        guard version == WireEnvelope.version else {
            throw WireProtocolError.unsupportedVersion
        }

        let payloadLength = Int(try buffer.readLittleEndian(UInt32.self, at: 8))
        let frameLength = WireEnvelope.headerLength + payloadLength
        guard buffer.count >= frameLength else {
            return nil
        }

        let frame = buffer.prefix(frameLength)
        buffer.removeSubrange(..<frameLength)
        return try WireEnvelope.decode(Data(frame))
    }
}
