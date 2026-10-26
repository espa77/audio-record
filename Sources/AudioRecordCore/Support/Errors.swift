import Foundation
import OSLog

public struct AudioRecordError: LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public enum Log {
    public static let subsystem = "com.esteiner.audiorecord"
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
