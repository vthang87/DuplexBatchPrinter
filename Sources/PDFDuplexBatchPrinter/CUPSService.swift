import Foundation

enum CUPSServiceError: LocalizedError {
    case commandFailed(command: String, message: String)
    case submissionResponse(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let message): "CUPS command \(command) failed: \(message)"
        case .submissionResponse(let response): "CUPS did not return a job ID: \(response)"
        }
    }
}

protocol PrintServicing: Sendable {
    func listPrinters() async throws -> [PrinterDescriptor]
    func submit(pdfURL: URL, printer: String, title: String, profile: PrinterProfile) async throws -> SubmittedPrintJob
    func waitUntilFinished(job: SubmittedPrintJob) async throws
    func cancel(job: SubmittedPrintJob) async
}

actor CUPSService: PrintServicing {
    private let pollInterval: Duration

    init(pollInterval: Duration = .seconds(2)) {
        self.pollInterval = pollInterval
    }

    func listPrinters() async throws -> [PrinterDescriptor] {
        let queues = try run("/usr/bin/lpstat", arguments: ["-e"])
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        let defaultOutput = (try? run("/usr/bin/lpstat", arguments: ["-d"])) ?? ""
        let defaultQueue = Self.parseDefaultPrinter(defaultOutput)
        return queues.map {
            PrinterDescriptor(queueName: $0, displayName: $0, isDefault: $0 == defaultQueue)
        }
    }

    func submit(pdfURL: URL, printer: String, title: String, profile: PrinterProfile) async throws -> SubmittedPrintJob {
        var arguments = ["-d", printer, "-t", title, "-o", "sides=one-sided", "-o", "copies=1", "-o", "number-up=1", "-o", "media=\(profile.paperSize.cupsValue)"]
        switch profile.colorMode {
        case .automatic: break
        case .grayscale: arguments += ["-o", "ColorModel=Gray"]
        case .color: arguments += ["-o", "ColorModel=RGB"]
        }
        for (key, value) in profile.cupsOptions.sorted(by: { $0.key < $1.key }) {
            arguments += ["-o", "\(key)=\(value)"]
        }
        let printerOptions = (try? run("/usr/bin/lpoptions", arguments: ["-p", printer, "-l"])) ?? ""
        if Self.supportsEpsonSkipBlankControl(printerOptions) {
            arguments += ["-o", "EPIJ_BSSv=0"]
        }
        arguments.append(pdfURL.path)

        let response = try run("/usr/bin/lp", arguments: arguments)
        guard let id = Self.parseSubmittedJobID(response) else {
            throw CUPSServiceError.submissionResponse(response)
        }
        return SubmittedPrintJob(id: id, printer: printer, title: title)
    }

    func waitUntilFinished(job: SubmittedPrintJob) async throws {
        var consecutiveMissingPolls = 0
        while !Task.isCancelled {
            // lpstat -o expects a destination (printer queue), not a request ID.
            // The returned rows start with request IDs such as "Printer-123".
            let active = try run(
                "/usr/bin/lpstat",
                arguments: Self.jobStatusArguments(printer: job.printer, completed: false),
                acceptsExitCodes: [0, 1]
            )
            if Self.containsJob(active, id: job.id) {
                consecutiveMissingPolls = 0
                try await Task.sleep(for: pollInterval)
                continue
            }

            let completed = try run(
                "/usr/bin/lpstat",
                arguments: Self.jobStatusArguments(printer: job.printer, completed: true),
                acceptsExitCodes: [0, 1]
            )
            if Self.containsJob(completed, id: job.id) { return }

            // Some drivers remove a finished job from both active and completed
            // history almost immediately. Confirm the absence on two polls so a
            // short submit/queue race is not mistaken for completion.
            consecutiveMissingPolls += 1
            if consecutiveMissingPolls >= 2 { return }
            try await Task.sleep(for: pollInterval)
        }
        throw CancellationError()
    }

    func cancel(job: SubmittedPrintJob) async {
        _ = try? run("/usr/bin/cancel", arguments: [job.id], acceptsExitCodes: [0, 1])
    }

    static func parseSubmittedJobID(_ output: String) -> String? {
        let pattern = #"request id is\s+([^\s]+-\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }

    static func parseDefaultPrinter(_ output: String) -> String? {
        output.split(separator: ":", maxSplits: 1).dropFirst().first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func jobStatusArguments(printer: String, completed: Bool) -> [String] {
        ["-W", completed ? "completed" : "not-completed", "-o", printer]
    }

    static func containsJob(_ output: String, id: String) -> Bool {
        output.split(whereSeparator: \Character.isNewline).contains { line in
            line.split(whereSeparator: \Character.isWhitespace).first.map(String.init) == id
        }
    }

    static func supportsEpsonSkipBlankControl(_ output: String) -> Bool {
        output.split(whereSeparator: \Character.isNewline).contains {
            $0.hasPrefix("EPIJ_BSSv/Skip Blank Page:")
        }
    }

    private func run(_ executable: String, arguments: [String], acceptsExitCodes: Set<Int32> = [0]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard acceptsExitCodes.contains(process.terminationStatus) else {
            throw CUPSServiceError.commandFailed(
                command: ([executable] + arguments).joined(separator: " "),
                message: error.isEmpty ? output : error
            )
        }
        return output
    }
}
