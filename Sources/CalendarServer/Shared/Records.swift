import Foundation

// Codes are the client contract. GraphQL reports them in extensions.code and
// MCP in the error payload; the message is a sentence for people.
enum ErrorCode: String, Encodable, Sendable {
  case invalidArgument = "INVALID_ARGUMENT"
  case notFound = "NOT_FOUND"
  case forbidden = "FORBIDDEN"
  case notAuthorized = "NOT_AUTHORIZED"
  case readOnly = "READ_ONLY"
  case unsupported = "UNSUPPORTED"
  case unsupportedOperation = "UNSUPPORTED_OPERATION"
  case calendarNotEmpty = "CALENDAR_NOT_EMPTY"
  case spanRequired = "SPAN_REQUIRED"
  case hasAttendees = "HAS_ATTENDEES"
  case resultTooLarge = "RESULT_TOO_LARGE"
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
  static func notAuthorized(_ message: String) -> Self {
    .init(code: .notAuthorized, message: message)
  }
  static func readOnly(_ message: String) -> Self { .init(code: .readOnly, message: message) }
  static func unsupported(_ message: String) -> Self { .init(code: .unsupported, message: message) }
  static func unsupportedOperation(_ message: String) -> Self {
    .init(code: .unsupportedOperation, message: message)
  }
  static func calendarNotEmpty(_ message: String) -> Self {
    .init(code: .calendarNotEmpty, message: message)
  }
  static func spanRequired(_ message: String) -> Self {
    .init(code: .spanRequired, message: message)
  }
  static func hasAttendees(_ message: String) -> Self {
    .init(code: .hasAttendees, message: message)
  }
  static func resultTooLarge(_ message: String) -> Self {
    .init(code: .resultTooLarge, message: message)
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

// Case order follows EventKit's Gregorian weekday numbers, 1 (Sunday) through 7.
enum Weekday: String, CaseIterable, Codable, Sendable {
  case sunday = "SUNDAY"
  case monday = "MONDAY"
  case tuesday = "TUESDAY"
  case wednesday = "WEDNESDAY"
  case thursday = "THURSDAY"
  case friday = "FRIDAY"
  case saturday = "SATURDAY"
  init?(number: Int) {
    guard (1...7).contains(number) else { return nil }
    self = Self.allCases[number - 1]
  }
}
// A repeating schedule's unit as both APIs spell it; RecurrenceFrequency is the stored form.
enum ScheduleFrequency: String, CaseIterable, Codable, Sendable {
  case daily = "DAILY"
  case weekly = "WEEKLY"
  case monthly = "MONTHLY"
  case yearly = "YEARLY"
  init?(_ stored: RecurrenceFrequency) {
    switch stored {
    case .daily: self = .daily
    case .weekly: self = .weekly
    case .monthly: self = .monthly
    case .yearly: self = .yearly
    case .unknown: return nil
    }
  }
}
struct StructuredLocation: Encodable, Sendable, Equatable {
  let title: String?
  let latitude: Double?
  let longitude: Double?
  let radius: Double
  enum CodingKeys: String, CodingKey { case title, latitude, longitude, radius }
}
enum AlarmProximity: String, CaseIterable, Encodable, Sendable { case none, enter, leave, unknown }
enum RecurrenceFrequency: String, CaseIterable, Encodable, Sendable {
  case daily, weekly, monthly, yearly, unknown
}
struct AlarmRecord: Encodable, Sendable {
  let action: String
  let soundName, emailAddress: String?
  let absoluteDate: String?
  let relativeOffset: Double
  let proximity: AlarmProximity
  let structuredLocation: StructuredLocation?
  enum CodingKeys: String, CodingKey {
    case action, soundName, emailAddress, absoluteDate, relativeOffset, proximity,
      structuredLocation
  }
}
struct RecurrenceDay: Encodable, Sendable {
  let dayOfTheWeek: Int
  let weekNumber: Int
  enum CodingKeys: String, CodingKey { case dayOfTheWeek, weekNumber }
}
struct RecurrenceEnd: Encodable, Sendable {
  let endDate: String?
  let occurrenceCount: Int
  enum CodingKeys: String, CodingKey { case endDate, occurrenceCount }
}
struct RecurrenceRecord: Encodable, Sendable {
  let frequency: RecurrenceFrequency
  let calendarIdentifier: String
  let interval: Int
  let firstDayOfTheWeek: Int
  let daysOfTheWeek: [RecurrenceDay]
  let daysOfTheMonth: [Int]
  let daysOfTheYear: [Int]
  let weeksOfTheYear: [Int]
  let monthsOfTheYear: [Int]
  let setPositions: [Int]
  let end: RecurrenceEnd?
  enum CodingKeys: String, CodingKey {
    case frequency, calendarIdentifier, interval, firstDayOfTheWeek, daysOfTheWeek, daysOfTheMonth
    case daysOfTheYear, weeksOfTheYear, monthsOfTheYear, setPositions, end
  }
}

// Read-only in EventKit: an event's status changes only at the provider.
enum EventStatus: String, CaseIterable, Codable, Sendable {
  case none = "NONE"
  case confirmed = "CONFIRMED"
  case tentative = "TENTATIVE"
  case canceled = "CANCELED"
}
enum ParticipantStatus: String, CaseIterable, Codable, Sendable {
  case unknown = "UNKNOWN"
  case pending = "PENDING"
  case accepted = "ACCEPTED"
  case declined = "DECLINED"
  case tentative = "TENTATIVE"
  case delegated = "DELEGATED"
  case completed = "COMPLETED"
  case inProcess = "IN_PROCESS"
}
enum ParticipantRole: String, CaseIterable, Codable, Sendable {
  case unknown = "UNKNOWN"
  case required = "REQUIRED"
  case optional = "OPTIONAL"
  case chair = "CHAIR"
  case nonParticipant = "NON_PARTICIPANT"
}
enum ParticipantType: String, CaseIterable, Codable, Sendable {
  case unknown = "UNKNOWN"
  case person = "PERSON"
  case room = "ROOM"
  case resource = "RESOURCE"
  case group = "GROUP"
}
// An organizer or attendee. EventKit exposes participants read-only.
struct ParticipantRecord: Encodable, Sendable {
  let name, url, email: String?
  let status: ParticipantStatus
  let role: ParticipantRole
  let type: ParticipantType
  let currentUser: Bool
  enum CodingKeys: String, CodingKey { case name, url, email, status, role, type, currentUser }
}
enum EventSortField: String, CaseIterable, Decodable, Sendable {
  case startDate = "START_DATE"
  case endDate = "END_DATE"
  case title = "TITLE"
  case creationDate = "CREATION_DATE"
  case modificationDate = "MODIFICATION_DATE"
}
// One event or one occurrence of a repeating event. Dates stay instants; EventViews
// projects them into the timed and all-day API fields.
struct EventRecord: Sendable {
  let id: String
  let seriesId: String?
  let eventIdentifier: String
  let externalId: String?
  let calendarId: String
  let title, notes, location, url: String?
  let structuredLocation: StructuredLocation?
  let start, end: Date
  let allDay: Bool
  let timeZone: String?
  let occurrenceDate: Date?
  let detached, recurring: Bool
  let availability: EventAvailability
  let status: EventStatus
  let organizer: ParticipantRecord?
  let attendees: [ParticipantRecord]
  let birthdayContactIdentifier: String?
  let creationDate, modificationDate: Date?
  let alarms: [AlarmRecord]
  let recurrenceRules: [RecurrenceRecord]
}
// A half-open span of time: from inclusive, before exclusive.
struct EventWindow: Sendable, Hashable {
  let from, before: Date
}
struct EventsData: Sendable {
  let calendars: CalendarData
  let events: [EventRecord]
  let window: EventWindow
}
// Counts of the events in one calendar that overlap a window. The attribute counts overlap.
struct CalendarSummary: Encodable, Sendable {
  let calendarId: String
  let from, before: String
  let total, allDay, timed, recurring, withAttendees, withAlarms: Int
  enum CodingKeys: String, CodingKey {
    case calendarId, from, before, total, allDay, timed, recurring, withAttendees, withAlarms
  }
}
// `events` are already limited to the window, as Search.events returns them.
func summarize(_ events: [EventRecord], window: EventWindow, calendarId: String)
  -> CalendarSummary
{
  let items = events.filter { $0.calendarId == calendarId }
  let allDay = items.filter(\.allDay).count
  return CalendarSummary(
    calendarId: calendarId, from: timestamp(window.from), before: timestamp(window.before),
    total: items.count, allDay: allDay, timed: items.count - allDay,
    recurring: items.filter(\.recurring).count,
    withAttendees: items.filter { !$0.attendees.isEmpty }.count,
    withAlarms: items.filter { !$0.alarms.isEmpty }.count)
}
