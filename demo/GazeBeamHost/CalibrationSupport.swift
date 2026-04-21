import CoreGraphics
import Foundation
import GazeProtocolKit

struct CalibrationCollector {
    var stepIndex: Int
    var targetNormalized: CGPoint
    var collectionStart: CFTimeInterval
    var collectionEnd: CFTimeInterval
    var samples: [ProviderSamplePayload] = []

    func stableSamples(minimumCount: Int) -> [ProviderSamplePayload]? {
        guard samples.count >= minimumCount else {
            return nil
        }
        guard samples.count >= 7 else {
            return samples
        }

        let keepMask = intersectingKeepMask(for: [
            samples.map { Double($0.gazeOriginPM[safe: 0] ?? 0) },
            samples.map { Double($0.gazeOriginPM[safe: 1] ?? 0) },
            samples.map { Double($0.gazeOriginPM[safe: 2] ?? 0) },
            samples.map { Double($0.gazeDirP[safe: 0] ?? 0) },
            samples.map { Double($0.gazeDirP[safe: 1] ?? 0) },
            samples.map { Double($0.gazeDirP[safe: 2] ?? 0) },
        ])
        let filtered = zip(samples, keepMask).compactMap { sample, keep in
            keep ? sample : nil
        }
        return filtered.count >= minimumCount ? filtered : samples
    }

    private func intersectingKeepMask(for components: [[Double]]) -> [Bool] {
        guard let sampleCount = components.first?.count else {
            return []
        }
        var keepMask = Array(repeating: true, count: sampleCount)
        for values in components {
            let componentMask = keepMaskForTrimmedValues(values)
            for index in keepMask.indices {
                keepMask[index] = keepMask[index] && componentMask[index]
            }
        }
        return keepMask
    }

    private func keepMaskForTrimmedValues(_ values: [Double]) -> [Bool] {
        guard values.count >= 7 else {
            return Array(repeating: true, count: values.count)
        }

        let trimCount = min(max(values.count / 6, 1), (values.count - 1) / 2)
        let ranked = values.enumerated().sorted { $0.element < $1.element }
        let kept = ranked.dropFirst(trimCount).dropLast(trimCount).map(\.offset)
        var mask = Array(repeating: false, count: values.count)
        for index in kept {
            mask[index] = true
        }
        return mask
    }
}

enum CalibrationGrid {
    static let targets: [CGPoint] = [
        CGPoint(x: 0.15, y: 0.18), CGPoint(x: 0.50, y: 0.18), CGPoint(x: 0.85, y: 0.18),
        CGPoint(x: 0.15, y: 0.50), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.85, y: 0.50),
        CGPoint(x: 0.15, y: 0.82), CGPoint(x: 0.50, y: 0.82), CGPoint(x: 0.85, y: 0.82),
    ]
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
