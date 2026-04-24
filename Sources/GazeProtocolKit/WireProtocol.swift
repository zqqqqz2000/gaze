import Foundation

public enum WireChannel: UInt8, Codable, Sendable {
    case control = 1
    case data = 2
}

public enum DataMessageKind: UInt8, Sendable {
    case providerSample = 1
    case healthSample = 2
    case calibrationAck = 3
}

public enum ControlMessageKind: String, Codable, Sendable {
    case hello
    case pair
    case startStream = "start_stream"
    case stopStream = "stop_stream"
    case beginCalibration = "begin_calibration"
    case showTarget = "show_target"
    case endCalibration = "end_calibration"
    case loadCalibration = "load_calibration"
    case requestStatus = "request_status"
}

public struct ControlMessageEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public var kind: ControlMessageKind
    public var payload: Payload

    public init(kind: ControlMessageKind, payload: Payload) {
        self.kind = kind
        self.payload = payload
    }
}

public struct WireEnvelope: Sendable, Equatable {
    public static let magic = "GZEP".data(using: .utf8)!
    public static let version: UInt16 = 1
    public static let headerLength = 16

    public var channel: WireChannel
    public var kind: UInt8
    public var payload: Data

    public init(channel: WireChannel, kind: UInt8, payload: Data) {
        self.channel = channel
        self.kind = kind
        self.payload = payload
    }

    public func encode() -> Data {
        var data = Data()
        data.append(Self.magic)
        data.appendLittleEndian(Self.version)
        data.append(channel.rawValue)
        data.append(kind)
        data.appendLittleEndian(UInt32(payload.count))
        data.appendLittleEndian(UInt32(0))
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> WireEnvelope {
        guard data.count >= Self.headerLength else {
            throw WireProtocolError.frameTooShort
        }
        guard data.prefix(4) == Self.magic else {
            throw WireProtocolError.badMagic
        }

        let version = try data.readLittleEndian(UInt16.self, at: 4)
        guard version == Self.version else {
            throw WireProtocolError.unsupportedVersion
        }
        guard let channel = WireChannel(rawValue: data[6]) else {
            throw WireProtocolError.badChannel
        }
        let kind = data[7]
        let length = try data.readLittleEndian(UInt32.self, at: 8)
        guard data.count == Self.headerLength + Int(length) else {
            throw WireProtocolError.badLength
        }
        return WireEnvelope(channel: channel, kind: kind, payload: data.subdata(in: Self.headerLength..<data.count))
    }
}

public enum WireProtocolError: Error {
    case frameTooShort
    case badMagic
    case unsupportedVersion
    case badChannel
    case badLength
    case badPayload
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { rawBuffer in
            append(contentsOf: rawBuffer)
        }
    }

    mutating func appendLittleEndian(_ value: Float) {
        appendLittleEndian(value.bitPattern)
    }

    func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) throws -> T {
        let length = MemoryLayout<T>.size
        guard offset + length <= count else {
            throw WireProtocolError.badPayload
        }
        let value = withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        return T(littleEndian: value)
    }

    func readFloat(at offset: Int) throws -> Float {
        let bitPattern = try readLittleEndian(UInt32.self, at: offset)
        return Float(bitPattern: bitPattern)
    }
}
