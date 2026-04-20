import Foundation

public struct QuadraticCalibrationSample: Sendable, Equatable {
    public var rawX: Double
    public var rawY: Double
    public var targetX: Double
    public var targetY: Double

    public init(rawX: Double, rawY: Double, targetX: Double, targetY: Double) {
        self.rawX = rawX
        self.rawY = rawY
        self.targetX = targetX
        self.targetY = targetY
    }
}

public enum QuadraticCalibrationCodingError: Error, Equatable {
    case invalidPayload
    case invalidCoefficientCount
}

public struct QuadraticCalibrationModel: Sendable, Equatable {
    private static let featureCount = 6

    private let coefficientsX: [Double]
    private let coefficientsY: [Double]

    public init?(samples: [QuadraticCalibrationSample]) {
        guard samples.count >= Self.featureCount else {
            return nil
        }

        let matrix = Self.normalEquationMatrix(samples: samples)
        let rhsX = Self.normalEquationVector(samples: samples, keyPath: \.targetX)
        let rhsY = Self.normalEquationVector(samples: samples, keyPath: \.targetY)

        guard
            let coefficientsX = Self.solve(matrix: matrix, vector: rhsX),
            let coefficientsY = Self.solve(matrix: matrix, vector: rhsY)
        else {
            return nil
        }

        self.coefficientsX = coefficientsX
        self.coefficientsY = coefficientsY
    }

    public init(serializedData: Data) throws {
        let payload = try JSONDecoder().decode(CodingPayload.self, from: serializedData)
        guard payload.version == 1 else {
            throw QuadraticCalibrationCodingError.invalidPayload
        }
        guard
            payload.coefficientsX.count == Self.featureCount,
            payload.coefficientsY.count == Self.featureCount
        else {
            throw QuadraticCalibrationCodingError.invalidCoefficientCount
        }

        self.coefficientsX = payload.coefficientsX
        self.coefficientsY = payload.coefficientsY
    }

    public func map(rawX: Double, rawY: Double) -> (x: Double, y: Double) {
        let features = Self.features(rawX: rawX, rawY: rawY)
        return (
            x: zip(coefficientsX, features).reduce(0) { $0 + ($1.0 * $1.1) },
            y: zip(coefficientsY, features).reduce(0) { $0 + ($1.0 * $1.1) }
        )
    }

    public func serializedData() throws -> Data {
        try JSONEncoder().encode(
            CodingPayload(
                version: 1,
                coefficientsX: coefficientsX,
                coefficientsY: coefficientsY
            )
        )
    }

    public func rootMeanSquareError(samples: [QuadraticCalibrationSample]) -> Double {
        guard !samples.isEmpty else {
            return 0
        }

        let totalSquaredError = samples.reduce(0.0) { partial, sample in
            let mapped = map(rawX: sample.rawX, rawY: sample.rawY)
            let dx = mapped.x - sample.targetX
            let dy = mapped.y - sample.targetY
            return partial + dx * dx + dy * dy
        }
        return sqrt(totalSquaredError / Double(samples.count))
    }

    private static func features(rawX: Double, rawY: Double) -> [Double] {
        [1.0, rawX, rawY, rawX * rawX, rawX * rawY, rawY * rawY]
    }

    private static func normalEquationMatrix(samples: [QuadraticCalibrationSample]) -> [[Double]] {
        var matrix = Array(repeating: Array(repeating: 0.0, count: Self.featureCount), count: Self.featureCount)
        for sample in samples {
            let features = features(rawX: sample.rawX, rawY: sample.rawY)
            for row in 0..<Self.featureCount {
                for column in 0..<Self.featureCount {
                    matrix[row][column] += features[row] * features[column]
                }
            }
        }
        return matrix
    }

    private static func normalEquationVector(
        samples: [QuadraticCalibrationSample],
        keyPath: KeyPath<QuadraticCalibrationSample, Double>
    ) -> [Double] {
        var vector = Array(repeating: 0.0, count: Self.featureCount)
        for sample in samples {
            let features = features(rawX: sample.rawX, rawY: sample.rawY)
            for index in 0..<Self.featureCount {
                vector[index] += features[index] * sample[keyPath: keyPath]
            }
        }
        return vector
    }

    private static func solve(matrix: [[Double]], vector: [Double]) -> [Double]? {
        var augmented = zip(matrix, vector).map { row, value in
            row + [value]
        }

        for pivot in 0..<Self.featureCount {
            var bestRow = pivot
            var bestValue = abs(augmented[pivot][pivot])
            for row in (pivot + 1)..<Self.featureCount {
                let candidate = abs(augmented[row][pivot])
                if candidate > bestValue {
                    bestValue = candidate
                    bestRow = row
                }
            }

            guard bestValue > 1e-12 else {
                return nil
            }

            if bestRow != pivot {
                augmented.swapAt(pivot, bestRow)
            }

            let pivotValue = augmented[pivot][pivot]
            for column in pivot...Self.featureCount {
                augmented[pivot][column] /= pivotValue
            }

            for row in 0..<Self.featureCount where row != pivot {
                let factor = augmented[row][pivot]
                if factor == 0 {
                    continue
                }
                for column in pivot...Self.featureCount {
                    augmented[row][column] -= factor * augmented[pivot][column]
                }
            }
        }

        return augmented.map { $0[Self.featureCount] }
    }
}

private struct CodingPayload: Codable {
    var version: Int
    var coefficientsX: [Double]
    var coefficientsY: [Double]
}

extension QuadraticCalibrationCodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Invalid calibration payload"
        case .invalidCoefficientCount:
            return "Calibration payload has an unexpected coefficient count"
        }
    }
}
