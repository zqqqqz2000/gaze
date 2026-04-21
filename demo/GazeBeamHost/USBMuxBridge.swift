import Darwin
import Foundation

final class USBMuxBridge: @unchecked Sendable {
    enum Event: Sendable {
        case started(String)
        case output(String)
        case stopped(Int32)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "gaze.beam.host.iproxy")
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var boundLocalPort: UInt16?

    var isRunning: Bool {
        process != nil
    }

    func start(localPort: UInt16, devicePort: UInt16) throws {
        stop()

        guard let executablePath = Self.resolveExecutablePath() else {
            throw NSError(
                domain: "USBMuxBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "iproxy not found. Install libimobiledevice or set GAZE_IPROXY_PATH."]
            )
        }

        try releaseLocalPortIfNeeded(localPort)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [String(localPort), String(devicePort)]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeOutput(from: handle)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeOutput(from: handle)
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else {
                return
            }
            self.queue.async {
                self.clearPipes()
                self.process = nil
                self.boundLocalPort = nil
                self.onEvent?(.stopped(terminatedProcess.terminationStatus))
            }
        }

        try process.run()

        guard Self.waitUntilProcessIsListening(process.processIdentifier, on: localPort, timeout: 2.0) else {
            clearPipes()
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw NSError(
                domain: "USBMuxBridge",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "iproxy did not begin listening on local port \(localPort)"]
            )
        }

        self.process = process
        boundLocalPort = localPort
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        onEvent?(.started(executablePath))
    }

    func stop() {
        clearPipes()
        guard let process else {
            return
        }
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
        boundLocalPort = nil
    }

    static func resolveExecutablePath() -> String? {
        if let override = ProcessInfo.processInfo.environment["GAZE_IPROXY_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        let fileManager = FileManager.default
        let defaultCandidates = [
            "/opt/homebrew/bin/iproxy",
            "/usr/local/bin/iproxy",
            "/usr/bin/iproxy",
        ]

        for candidate in defaultCandidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("iproxy").path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func clearPipes() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func consumeOutput(from handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }
            onEvent?(.output(line))
        }
    }

    private func releaseLocalPortIfNeeded(_ port: UInt16) throws {
        for pid in Self.listenerPIDs(on: port) {
            if let runningProcess = process, pid == runningProcess.processIdentifier {
                continue
            }

            let command = Self.commandLine(for: pid) ?? "pid \(pid)"
            guard command.contains("iproxy") else {
                throw NSError(
                    domain: "USBMuxBridge",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "local port \(port) is already used by \(command)"]
                )
            }

            onEvent?(.output("terminating stale iproxy pid \(pid) on local port \(port)"))
            kill(pid, SIGTERM)

            if Self.waitUntilPortIsFree(port, timeout: 1.0) {
                continue
            }

            onEvent?(.output("forcing stale iproxy pid \(pid) to exit"))
            kill(pid, SIGKILL)

            guard Self.waitUntilPortIsFree(port, timeout: 1.0) else {
                throw NSError(
                    domain: "USBMuxBridge",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "failed to reclaim local port \(port) from stale iproxy"]
                )
            }
        }
    }

    private static func waitUntilPortIsFree(_ port: UInt16, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listenerPIDs(on: port).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return listenerPIDs(on: port).isEmpty
    }

    private static func waitUntilProcessIsListening(_ pid: Int32, on port: UInt16, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listenerPIDs(on: port).contains(pid) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return listenerPIDs(on: port).contains(pid)
    }

    private static func listenerPIDs(on port: UInt16) -> [Int32] {
        guard let output = runTool(
            "/usr/sbin/lsof",
            arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        ) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func commandLine(for pid: Int32) -> String? {
        runTool("/bin/ps", arguments: ["-p", String(pid), "-o", "command="])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runTool(_ executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
