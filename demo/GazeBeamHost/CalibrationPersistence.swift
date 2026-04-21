import Foundation
import GazeCoreKit

struct CalibrationPersistence {
    private let fileManager: FileManager
    private let calibrationURL: URL
    private let legacyCalibrationURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directoryURL = applicationSupportURL.appendingPathComponent("GazeBeamHost", isDirectory: true)
        self.calibrationURL = directoryURL.appendingPathComponent("core-calibration.blob", isDirectory: false)
        self.legacyCalibrationURL = directoryURL.appendingPathComponent("quadratic-calibration.json", isDirectory: false)
    }

    func load() throws -> GazeCalibration? {
        guard fileManager.fileExists(atPath: calibrationURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: calibrationURL)
        return try GazeCalibration(serializedData: data)
    }

    func save(_ calibration: GazeCalibration) throws {
        let directoryURL = calibrationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try calibration.serializedData()
        try data.write(to: calibrationURL, options: .atomic)
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: calibrationURL.path) else {
            if fileManager.fileExists(atPath: legacyCalibrationURL.path) {
                try fileManager.removeItem(at: legacyCalibrationURL)
            }
            return
        }
        try fileManager.removeItem(at: calibrationURL)
        if fileManager.fileExists(atPath: legacyCalibrationURL.path) {
            try fileManager.removeItem(at: legacyCalibrationURL)
        }
    }
}
