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

        guard let channel = WireChannel(rawValue: buffer[6]) else {
            throw WireProtocolError.badChannel
        }
        let kind = buffer[7]
        let payload = buffer.subdata(in: WireEnvelope.headerLength..<frameLength)
        buffer.removeSubrange(..<frameLength)
        return WireEnvelope(channel: channel, kind: kind, payload: payload)
    }
}
