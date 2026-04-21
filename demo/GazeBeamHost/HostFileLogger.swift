import Foundation

final class HostFileLogger: @unchecked Sendable {
    static let shared = HostFileLogger()

    let logFileURL: URL

    private let queue = DispatchQueue(label: "gaze.beam.host.file-logger")

    private init(fileManager: FileManager = .default) {
        let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        let logsDirectoryURL = libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("GazeBeamHost", isDirectory: true)
        logFileURL = logsDirectoryURL.appendingPathComponent("host.log", isDirectory: false)

        try? fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }

        appendRaw("===== session \(Self.timestampString(for: Date())) =====")
    }

    func append(_ line: String) {
        appendRaw(line)
    }

    private func appendRaw(_ line: String) {
        queue.async { [logFileURL] in
            guard let data = "\(line)\n".data(using: .utf8) else {
                return
            }

            do {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer {
                    try? handle.close()
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                fputs("HostFileLogger write failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private static func timestampString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
