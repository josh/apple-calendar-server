import Foundation

// Codes are the client contract. GraphQL reports them in extensions.code and
// MCP in the error payload; the message is a sentence for people.
enum ErrorCode: String, Encodable, Sendable {
  case invalidArgument = "INVALID_ARGUMENT"
  case notFound = "NOT_FOUND"
  case forbidden = "FORBIDDEN"
  case readOnly = "READ_ONLY"
  case unsupported = "UNSUPPORTED"
  case unsupportedOperation = "UNSUPPORTED_OPERATION"
  case writeFailed = "WRITE_FAILED"
  case writeApplied = "WRITE_APPLIED"
  case internalError = "INTERNAL"
}
struct ServerError: Error, CustomStringConvertible, Sendable {
  let code: ErrorCode
  let message: String
  var description: String { message }
  static func invalidArgument(_ message: String) -> Self {
    .init(code: .invalidArgument, message: message)
  }
  static func notFound(_ message: String) -> Self { .init(code: .notFound, message: message) }
  static func forbidden(_ message: String) -> Self { .init(code: .forbidden, message: message) }
  static func readOnly(_ message: String) -> Self { .init(code: .readOnly, message: message) }
  static func unsupported(_ message: String) -> Self { .init(code: .unsupported, message: message) }
  static func unsupportedOperation(_ message: String) -> Self {
    .init(code: .unsupportedOperation, message: message)
  }
  static func writeFailed(_ message: String) -> Self { .init(code: .writeFailed, message: message) }
  static func writeApplied(_ message: String) -> Self {
    .init(code: .writeApplied, message: message)
  }
  static func internalError(_ message: String) -> Self {
    .init(code: .internalError, message: message)
  }
}

struct SourceRecord: Encodable, Sendable {
  let id: String
  let title: String
  let type: Int
  enum CodingKeys: String, CodingKey { case id, title, type }
}
// How EventKit classifies a calendar's storage; the raw value is the API and label spelling.
enum CalendarType: String, CaseIterable, Codable, Sendable {
  case local = "LOCAL"
  case calDAV = "CALDAV"
  case exchange = "EXCHANGE"
  case subscription = "SUBSCRIPTION"
  case birthday = "BIRTHDAY"
  case unknown = "UNKNOWN"
}
// Values an event's availability can take; notSupported is what a calendar without
// availability reports for its events.
enum EventAvailability: String, CaseIterable, Codable, Sendable {
  case notSupported = "NOT_SUPPORTED"
  case busy = "BUSY"
  case free = "FREE"
  case tentative = "TENTATIVE"
  case unavailable = "UNAVAILABLE"
}
struct CalendarRecord: Encodable, Sendable {
  let id: String, name: String
  let color: String?
  let source: SourceRecord
  let type: CalendarType
  let allowsContentModifications, allowsCalendarModifications, subscribed, immutable: Bool
  let supportedAvailabilities: [EventAvailability]
  enum CodingKeys: String, CodingKey {
    case id, name, color, source, type, allowsContentModifications, allowsCalendarModifications
    case subscribed, immutable, supportedAvailabilities
  }
}

struct CalendarData: Sendable {
  let calendars: [CalendarRecord]
  let defaultCalendarId: String?
  var accounts: [AccountRecord] {
    var seen = Set<String>()
    return calendars.compactMap {
      seen.insert($0.source.id).inserted
        ? AccountRecord(id: $0.source.id, name: $0.source.title) : nil
    }.sorted { $0.id < $1.id }
  }
  var defaultCalendar: CalendarRecord? { calendars.first { $0.id == defaultCalendarId } }
  var defaultAccount: AccountRecord? { accounts.first { $0.id == defaultCalendar?.source.id } }
}
struct AccountRecord: Encodable, Sendable {
  let id: String
  let name: String
  enum CodingKeys: String, CodingKey { case id, name }
}
