import Foundation
import simd

public struct ScreenPlaneCalibrationSample: Sendable, Equatable {
    public var origin: SIMD3<Double>
    public var direction: SIMD3<Double>
    public var targetX: Double
    public var targetY: Double

    public init(origin: SIMD3<Double>, direction: SIMD3<Double>, targetX: Double, targetY: Double) {
        self.origin = origin
        self.direction = simd_normalize(direction)
        self.targetX = targetX
        self.targetY = targetY
    }
}

public enum ScreenPlaneCalibrationCodingError: Error, Equatable {
    case invalidPayload
    case invalidVectorLength
}

public struct ScreenPlaneCalibrationModel: Sendable, Equatable {
    private let origin: SIMD3<Double>
    private let axisX: SIMD3<Double>
    private let axisY: SIMD3<Double>

    public init?(samples: [ScreenPlaneCalibrationSample]) {
        guard samples.count >= 4 else {
            return nil
        }

        let unknownCount = 9 + samples.count
        var normalMatrix = Array(repeating: Array(repeating: 0.0, count: unknownCount), count: unknownCount)
        var normalVector = Array(repeating: 0.0, count: unknownCount)

        for (sampleIndex, sample) in samples.enumerated() {
            let direction = simd_normalize(sample.direction)
            for component in 0..<3 {
                var row = Array(repeating: 0.0, count: unknownCount)
                row[component] = 1.0
                row[3 + component] = sample.targetX
                row[6 + component] = sample.targetY
                row[9 + sampleIndex] = -direction[component]

                Self.accumulateNormalEquation(matrix: &normalMatrix, vector: &normalVector, row: row, rhs: sample.origin[component])
            }
        }

        guard let solution = Self.solve(matrix: normalMatrix, vector: normalVector) else {
            return nil
        }

        self.origin = SIMD3(solution[0], solution[1], solution[2])
        self.axisX = SIMD3(solution[3], solution[4], solution[5])
        self.axisY = SIMD3(solution[6], solution[7], solution[8])
    }

    public init(serializedData: Data) throws {
        let payload = try JSONDecoder().decode(CodingPayload.self, from: serializedData)
        guard payload.version == 1 else {
            throw ScreenPlaneCalibrationCodingError.invalidPayload
        }
        guard payload.origin.count == 3, payload.axisX.count == 3, payload.axisY.count == 3 else {
            throw ScreenPlaneCalibrationCodingError.invalidVectorLength
        }

        self.origin = SIMD3(payload.origin[0], payload.origin[1], payload.origin[2])
        self.axisX = SIMD3(payload.axisX[0], payload.axisX[1], payload.axisX[2])
        self.axisY = SIMD3(payload.axisY[0], payload.axisY[1], payload.axisY[2])
    }

    public func serializedData() throws -> Data {
        try JSONEncoder().encode(
            CodingPayload(
                version: 1,
                origin: [origin.x, origin.y, origin.z],
                axisX: [axisX.x, axisX.y, axisX.z],
                axisY: [axisY.x, axisY.y, axisY.z]
            )
        )
    }

    public func map(origin rayOrigin: SIMD3<Double>, direction rayDirection: SIMD3<Double>) -> (x: Double, y: Double)? {
        let direction = simd_normalize(rayDirection)
        let normal = simd_cross(axisX, axisY)
        let denominator = simd_dot(normal, direction)
        guard abs(denominator) > 1e-9 else {
            return nil
        }

        let distance = simd_dot(normal, origin - rayOrigin) / denominator
        guard distance.isFinite, distance > 0 else {
            return nil
        }

        let intersection = rayOrigin + direction * distance
        let relative = intersection - origin

        let xx = simd_dot(axisX, axisX)
        let xy = simd_dot(axisX, axisY)
        let yy = simd_dot(axisY, axisY)
        let determinant = xx * yy - xy * xy
        guard abs(determinant) > 1e-9 else {
            return nil
        }

        let rx = simd_dot(axisX, relative)
        let ry = simd_dot(axisY, relative)
        let x = (rx * yy - ry * xy) / determinant
        let y = (ry * xx - rx * xy) / determinant
        guard x.isFinite, y.isFinite else {
            return nil
        }
        return (x, y)
    }

    public func rootMeanSquareError(samples: [ScreenPlaneCalibrationSample]) -> Double {
        guard !samples.isEmpty else {
            return 0
        }

        let totalSquaredError = samples.reduce(0.0) { partial, sample in
            guard let mapped = map(origin: sample.origin, direction: sample.direction) else {
                return partial + 1.0
            }
            let dx = mapped.x - sample.targetX
            let dy = mapped.y - sample.targetY
            return partial + dx * dx + dy * dy
        }
        return sqrt(totalSquaredError / Double(samples.count))
    }

    private static func accumulateNormalEquation(
        matrix: inout [[Double]],
        vector: inout [Double],
        row: [Double],
        rhs: Double
    ) {
        for column in row.indices {
            vector[column] += row[column] * rhs
            for inner in row.indices {
                matrix[column][inner] += row[column] * row[inner]
            }
        }
    }

    private static func solve(matrix: [[Double]], vector: [Double]) -> [Double]? {
        let size = vector.count
        var augmented = zip(matrix, vector).map { row, value in
            row + [value]
        }

        for pivot in 0..<size {
            var bestRow = pivot
            var bestValue = abs(augmented[pivot][pivot])
            for row in (pivot + 1)..<size {
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
            for column in pivot...size {
                augmented[pivot][column] /= pivotValue
            }

            for row in 0..<size where row != pivot {
                let factor = augmented[row][pivot]
                if factor == 0 {
                    continue
                }
                for column in pivot...size {
                    augmented[row][column] -= factor * augmented[pivot][column]
                }
            }
        }

        return augmented.map { $0[size] }
    }
}

private struct CodingPayload: Codable {
    var version: Int
    var origin: [Double]
    var axisX: [Double]
    var axisY: [Double]
}

extension ScreenPlaneCalibrationCodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Invalid screen plane calibration payload"
        case .invalidVectorLength:
            return "Screen plane calibration payload has an invalid vector length"
        }
    }
}
