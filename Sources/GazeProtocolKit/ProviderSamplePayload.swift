import Foundation

public struct ProviderSamplePayload: Codable, Equatable, Sendable {
    public var timestampNs: UInt64
    public var trackingFlags: UInt32

    public var gazeOriginPM: [Float]
    public var gazeDirP: [Float]

    public var leftEyeOriginPM: [Float]
    public var leftEyeDirP: [Float]
    public var rightEyeOriginPM: [Float]
    public var rightEyeDirP: [Float]

    public var headRotPFQ: [Float]
    public var headPosPM: [Float]
    public var lookAtPointFM: [Float]

    public var confidence: Float
    public var faceDistanceM: Float

    public init(
        timestampNs: UInt64,
        trackingFlags: UInt32,
        gazeOriginPM: [Float],
        gazeDirP: [Float],
        leftEyeOriginPM: [Float],
        leftEyeDirP: [Float],
        rightEyeOriginPM: [Float],
        rightEyeDirP: [Float],
        headRotPFQ: [Float],
        headPosPM: [Float],
        lookAtPointFM: [Float],
        confidence: Float,
        faceDistanceM: Float
    ) {
        self.timestampNs = timestampNs
        self.trackingFlags = trackingFlags
        self.gazeOriginPM = ProviderSamplePayload.fixLength(gazeOriginPM, count: 3)
        self.gazeDirP = ProviderSamplePayload.fixLength(gazeDirP, count: 3)
        self.leftEyeOriginPM = ProviderSamplePayload.fixLength(leftEyeOriginPM, count: 3)
        self.leftEyeDirP = ProviderSamplePayload.fixLength(leftEyeDirP, count: 3)
        self.rightEyeOriginPM = ProviderSamplePayload.fixLength(rightEyeOriginPM, count: 3)
        self.rightEyeDirP = ProviderSamplePayload.fixLength(rightEyeDirP, count: 3)
        self.headRotPFQ = ProviderSamplePayload.fixLength(headRotPFQ, count: 4)
        self.headPosPM = ProviderSamplePayload.fixLength(headPosPM, count: 3)
        self.lookAtPointFM = ProviderSamplePayload.fixLength(lookAtPointFM, count: 3)
        self.confidence = confidence
        self.faceDistanceM = faceDistanceM
    }

    private static func fixLength(_ values: [Float], count: Int) -> [Float] {
        if values.count == count {
            return values
        }
        if values.count > count {
            return Array(values.prefix(count))
        }
        return values + Array(repeating: 0.0, count: count - values.count)
    }
}
