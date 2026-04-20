import Foundation
import GazeProtocolKit

struct CalibrationPersistence {
    private let fileManager: FileManager
    private let calibrationURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.calibrationURL = applicationSupportURL
            .appendingPathComponent("GazeBeamHost", isDirectory: true)
            .appendingPathComponent("quadratic-calibration.json", isDirectory: false)
    }

    func load() throws -> QuadraticCalibrationModel? {
        guard fileManager.fileExists(atPath: calibrationURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: calibrationURL)
        return try QuadraticCalibrationModel(serializedData: data)
    }

    func save(_ model: QuadraticCalibrationModel) throws {
        let directoryURL = calibrationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try model.serializedData()
        try data.write(to: calibrationURL, options: .atomic)
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: calibrationURL.path) else {
            return
        }
        try fileManager.removeItem(at: calibrationURL)
    }
}
