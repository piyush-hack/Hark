import Foundation
import os

public enum Log {
    private static let logger = Logger(subsystem: "dev.hark.Hark", category: "hark")
    public static var echoToConsole = false

    private static let fileQueue = DispatchQueue(label: "dev.hark.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Plain-text log at ~/Library/Application Support/Hark/hark.log (rotated at 2 MB) for bug reports.
    private static func append(_ line: String) {
        let url = Paths.appSupport.appendingPathComponent("hark.log")
        let entry = "\(stamp.string(from: Date())) \(line)\n"
        fileQueue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: url.appendingPathExtension("old"))
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("old"))
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(entry.utf8))
                try? handle.close()
            } else {
                try? Data(entry.utf8).write(to: url)
            }
        }
    }

    public static func info(_ message: @autoclosure () -> String) {
        let text = message()
        append(text)
        logger.notice("\(text, privacy: .public)")
        if echoToConsole { FileHandle.standardError.write(Data("· \(text)\n".utf8)) }
    }

    public static func error(_ message: @autoclosure () -> String) {
        let text = message()
        append("ERROR " + text)
        logger.error("\(text, privacy: .public)")
        if echoToConsole { FileHandle.standardError.write(Data("✗ \(text)\n".utf8)) }
    }
}

public struct HarkError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
