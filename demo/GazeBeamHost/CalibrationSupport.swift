import CoreGraphics
import Foundation

struct CalibrationRawPoint {
    var x: Double
    var y: Double

    init(sampleX: Double, sampleY: Double) {
        self.x = sampleX
        self.y = sampleY
    }
}

struct CalibrationCollector {
    var stepIndex: Int
    var targetNormalized: CGPoint
    var collectionStart: CFTimeInterval
    var collectionEnd: CFTimeInterval
    var rawSamples: [CalibrationRawPoint] = []

    func averageRawPoint(minimumCount: Int) -> CalibrationRawPoint? {
        guard rawSamples.count >= minimumCount else {
            return nil
        }

        let xs = trimmed(rawSamples.map(\.x))
        let ys = trimmed(rawSamples.map(\.y))
        return CalibrationRawPoint(
            sampleX: xs.reduce(0, +) / Double(xs.count),
            sampleY: ys.reduce(0, +) / Double(ys.count)
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
