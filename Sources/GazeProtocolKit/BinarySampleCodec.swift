import Foundation

public enum BinarySampleCodec {
    private static let floatCount = 31
    private static let payloadLength = 8 + 4 + (floatCount * 4)

    public static func encode(_ sample: ProviderSamplePayload) -> Data {
        var data = Data(capacity: payloadLength)
        data.appendLittleEndian(sample.timestampNs)
        data.appendLittleEndian(sample.trackingFlags)
        sample.gazeOriginPM.forEach { data.appendLittleEndian($0) }
        sample.gazeDirP.forEach { data.appendLittleEndian($0) }
        sample.leftEyeOriginPM.forEach { data.appendLittleEndian($0) }
        sample.leftEyeDirP.forEach { data.appendLittleEndian($0) }
        sample.rightEyeOriginPM.forEach { data.appendLittleEndian($0) }
        sample.rightEyeDirP.forEach { data.appendLittleEndian($0) }
        sample.headRotPFQ.forEach { data.appendLittleEndian($0) }
        sample.headPosPM.forEach { data.appendLittleEndian($0) }
        sample.lookAtPointFM.forEach { data.appendLittleEndian($0) }
        data.appendLittleEndian(sample.confidence)
        data.appendLittleEndian(sample.faceDistanceM)
        return data
    }

    public static func decode(_ data: Data) throws -> ProviderSamplePayload {
        guard data.count == payloadLength else {
            throw WireProtocolError.badPayload
        }
        var offset = 0
        let timestampNs = try data.readLittleEndian(UInt64.self, at: offset)
        offset += 8
        let trackingFlags = try data.readLittleEndian(UInt32.self, at: offset)
        offset += 4

        func readFloatArray(_ count: Int) throws -> [Float] {
            var result: [Float] = []
            result.reserveCapacity(count)
            for _ in 0..<count {
                result.append(try data.readFloat(at: offset))
                offset += 4
            }
            return result
        }

        return ProviderSamplePayload(
            timestampNs: timestampNs,
            trackingFlags: trackingFlags,
            gazeOriginPM: try readFloatArray(3),
            gazeDirP: try readFloatArray(3),
            leftEyeOriginPM: try readFloatArray(3),
            leftEyeDirP: try readFloatArray(3),
            rightEyeOriginPM: try readFloatArray(3),
            rightEyeDirP: try readFloatArray(3),
            headRotPFQ: try readFloatArray(4),
            headPosPM: try readFloatArray(3),
            lookAtPointFM: try readFloatArray(3),
            confidence: try data.readFloat(at: offset),
            faceDistanceM: try data.readFloat(at: offset + 4)
        )
    }
}
