#if canImport(ARKit) && canImport(UIKit)
import ARKit
import Foundation
import simd

public enum ProviderState: Sendable, Equatable {
    case idle
    case running
    case unsupported
    case interrupted
}

public final class GazeProvider: NSObject, ARSessionDelegate {
    public var onSample: (@Sendable (ProviderSamplePayload) -> Void)?
    public var onStateChanged: (@Sendable (ProviderState) -> Void)?
    public var streamClient: ProviderStreamClient?

    private let session = ARSession()
    private var state: ProviderState = .idle {
        didSet {
            if state != oldValue {
                onStateChanged?(state)
            }
        }
    }

    public override init() {
        super.init()
        session.delegate = self
    }

    public func start() throws {
        guard ARFaceTrackingConfiguration.isSupported else {
            state = .unsupported
            throw NSError(domain: "GazeProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "ARFaceTracking not supported"])
        }
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        state = .running
    }

    public func stop() {
        session.pause()
        state = .idle
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        state = .interrupted
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        state = .idle
    }

    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard state == .running else {
            return
        }
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
            return
        }
        let sample = buildSample(from: faceAnchor)
        onSample?(sample)
        streamClient?.sendSample(sample)
    }

    private func buildSample(from faceAnchor: ARFaceAnchor) -> ProviderSamplePayload {
        let faceTransform = faceAnchor.transform
        let leftEyeTransform = simd_mul(faceTransform, faceAnchor.leftEyeTransform)
        let rightEyeTransform = simd_mul(faceTransform, faceAnchor.rightEyeTransform)

        let leftEyeOrigin = leftEyeTransform.translation
        let rightEyeOrigin = rightEyeTransform.translation
        let gazeOrigin = (leftEyeOrigin + rightEyeOrigin) / 2.0

        let lookAtProvider = simd_mul(faceTransform, SIMD4<Float>(faceAnchor.lookAtPoint.x, faceAnchor.lookAtPoint.y, faceAnchor.lookAtPoint.z, 1.0))
        let fusedDirection = simd_normalize(SIMD3<Float>(lookAtProvider.x, lookAtProvider.y, lookAtProvider.z) - gazeOrigin)

        let leftDirection = simd_normalize(leftEyeTransform.forwardAxis)
        let rightDirection = simd_normalize(rightEyeTransform.forwardAxis)
        let headQuaternion = simd_quatf(faceTransform)
        let headPosition = faceTransform.translation

        let confidence = estimateConfidence(from: faceAnchor, facePosition: headPosition)

        return ProviderSamplePayload(
            timestampNs: DispatchTime.now().uptimeNanoseconds,
            trackingFlags: confidence >= 0.5 ? 1 : 3,
            gazeOriginPM: gazeOrigin.array3,
            gazeDirP: fusedDirection.array3,
            leftEyeOriginPM: leftEyeOrigin.array3,
            leftEyeDirP: leftDirection.array3,
            rightEyeOriginPM: rightEyeOrigin.array3,
            rightEyeDirP: rightDirection.array3,
            headRotPFQ: [headQuaternion.vector.x, headQuaternion.vector.y, headQuaternion.vector.z, headQuaternion.vector.w],
            headPosPM: headPosition.array3,
            lookAtPointFM: [faceAnchor.lookAtPoint.x, faceAnchor.lookAtPoint.y, faceAnchor.lookAtPoint.z],
            confidence: confidence,
            faceDistanceM: simd_length(headPosition)
        )
    }

    private func estimateConfidence(from faceAnchor: ARFaceAnchor, facePosition: SIMD3<Float>) -> Float {
        let distance = simd_length(facePosition)
        if !faceAnchor.isTracked {
            return 0.1
        }
        if distance < 0.18 || distance > 0.9 {
            return 0.3
        }
        return 1.0
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    var forwardAxis: SIMD3<Float> {
        SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z)
    }
}

private extension SIMD3 where Scalar == Float {
    var array3: [Float] {
        [x, y, z]
    }
}
#endif
