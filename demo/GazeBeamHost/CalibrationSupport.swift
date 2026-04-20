import CoreGraphics
import Foundation
import GazeProtocolKit
import simd

struct CalibrationRaySample {
    var origin: SIMD3<Double>
    var direction: SIMD3<Double>

    init(origin: SIMD3<Double>, direction: SIMD3<Double>) {
        self.origin = origin
        self.direction = simd_normalize(direction)
    }

    init?(providerSample: ProviderSamplePayload) {
        guard providerSample.gazeOriginPM.count == 3, providerSample.gazeDirP.count == 3 else {
            return nil
        }
        self.init(
            origin: SIMD3(
                Double(providerSample.gazeOriginPM[0]),
                Double(providerSample.gazeOriginPM[1]),
                Double(providerSample.gazeOriginPM[2])
            ),
            direction: SIMD3(
                Double(providerSample.gazeDirP[0]),
                Double(providerSample.gazeDirP[1]),
                Double(providerSample.gazeDirP[2])
            )
        )
    }
}

struct CalibrationCollector {
    var stepIndex: Int
    var targetNormalized: CGPoint
    var collectionStart: CFTimeInterval
    var collectionEnd: CFTimeInterval
    var raySamples: [CalibrationRaySample] = []

    func averageRaySample(minimumCount: Int) -> CalibrationRaySample? {
        guard raySamples.count >= minimumCount else {
            return nil
        }

        let originX = trimmed(raySamples.map(\.origin.x))
        let originY = trimmed(raySamples.map(\.origin.y))
        let originZ = trimmed(raySamples.map(\.origin.z))
        let directionX = trimmed(raySamples.map(\.direction.x))
        let directionY = trimmed(raySamples.map(\.direction.y))
        let directionZ = trimmed(raySamples.map(\.direction.z))

        return CalibrationRaySample(
            origin: SIMD3(
                originX.reduce(0, +) / Double(originX.count),
                originY.reduce(0, +) / Double(originY.count),
                originZ.reduce(0, +) / Double(originZ.count)
            ),
            direction: SIMD3(
                directionX.reduce(0, +) / Double(directionX.count),
                directionY.reduce(0, +) / Double(directionY.count),
                directionZ.reduce(0, +) / Double(directionZ.count)
            )
        )
    }

    private func trimmed(_ values: [Double]) -> [Double] {
        guard values.count >= 5 else {
            return values
        }

        let sorted = values.sorted()
        let trimCount = min(max(sorted.count / 6, 1), (sorted.count - 1) / 2)
        return Array(sorted.dropFirst(trimCount).dropLast(trimCount))
    }
}

enum CalibrationGrid {
    static let targets: [CGPoint] = [
        CGPoint(x: 0.15, y: 0.18), CGPoint(x: 0.50, y: 0.18), CGPoint(x: 0.85, y: 0.18),
        CGPoint(x: 0.15, y: 0.50), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.85, y: 0.50),
        CGPoint(x: 0.15, y: 0.82), CGPoint(x: 0.50, y: 0.82), CGPoint(x: 0.85, y: 0.82),
    ]
}
