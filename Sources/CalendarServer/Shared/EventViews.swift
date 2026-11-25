import Foundation

// API projections of stored events, alarms, and recurrence rules.
extension EventRecord {
  var startDate: String? { allDay ? nil : timestamp(start) }
  var endDate: String? { allDay ? nil : timestamp(end) }
  var allDayStartDate: String? { allDay ? localDay(start) : nil }
  var allDayEndDate: String? { allDay ? lastAllDayDay(start: start, end: end) : nil }
  // The current user's own participation, when they are an attendee.
  var myStatus: ParticipantStatus? { attendees.first(where: \.currentUser)?.status }
}

struct RecurrenceView: Encodable {
  struct Day: Encodable {
    let day: Weekday
    let ordinal: Int?
    enum CodingKeys: String, CodingKey { case day, ordinal }
  }
  struct End: Encodable {
    let until: String?
    let count: Int?
    enum CodingKeys: String, CodingKey { case until, count }
  }
  let frequency: ScheduleFrequency
  let interval: Int
  let daysOfWeek: [Day]?
  let daysOfMonth: [Int]?, monthsOfYear: [Int]?, weeksOfYear: [Int]?, daysOfYear: [Int]?,
    setPositions: [Int]?
  let end: End?
  enum CodingKeys: String, CodingKey {
    case frequency, interval, daysOfWeek, daysOfMonth, monthsOfYear, weeksOfYear, daysOfYear
    case setPositions, end
  }
  init(_ rule: RecurrenceRecord) throws {
    guard let frequency = ScheduleFrequency(rule.frequency) else {
      throw ServerError.unsupported("unknown recurrence frequency")
    }
    self.frequency = frequency
    interval = rule.interval
    let days = try rule.daysOfTheWeek.map { value in
      guard let day = Weekday(number: value.dayOfTheWeek) else {
        throw ServerError.unsupported("unknown recurrence weekday")
      }
      return Day(
        day: day,
        ordinal: value.weekNumber == 0 ? nil : value.weekNumber)
    }
    daysOfWeek = days.isEmpty ? nil : days
    func constraint(_ values: [Int]) -> [Int]? { values.isEmpty ? nil : values }
    daysOfMonth = constraint(rule.daysOfTheMonth)
    monthsOfYear = constraint(rule.monthsOfTheYear)
    weeksOfYear = constraint(rule.weeksOfTheYear)
    daysOfYear = constraint(rule.daysOfTheYear)
    setPositions = constraint(rule.setPositions)
    if let value = rule.end {
      guard
        (value.endDate != nil && value.occurrenceCount == 0)
          || (value.endDate == nil && value.occurrenceCount > 0)
      else { throw ServerError.unsupported("ambiguous recurrence end") }
      end = End(
        until: value.endDate, count: value.occurrenceCount > 0 ? value.occurrenceCount : nil)
    } else {
      end = nil
    }
  }
}
enum AlarmKind: String, Encodable, Sendable {
  case absolute = "AbsoluteAlarm"
  case relative = "RelativeAlarm"
}
// An alert at a fixed time or relative to the event's start. Location triggers are
// not projected; rawAlarms holds them.
struct AlarmView: Encodable {
  let kind: AlarmKind
  let action: String
  let soundName, emailAddress: String?
  let at: String?
  let offsetSeconds: Double?
  enum CodingKeys: String, CodingKey {
    case kind, action, soundName, emailAddress, at, offsetSeconds
  }
  init(_ alarm: AlarmRecord) throws {
    action = alarm.action
    soundName = alarm.soundName
    emailAddress = alarm.emailAddress
    guard alarm.relativeOffset.isFinite else {
      throw ServerError.unsupported("nonfinite alarm offset")
    }
    guard alarm.structuredLocation == nil, alarm.proximity == .none else {
      throw ServerError.unsupported("location alarm; inspect rawAlarms")
    }
    if let date = alarm.absoluteDate {
      guard alarm.relativeOffset == 0 else {
        throw ServerError.unsupported("combined alarm triggers; inspect rawAlarms")
      }
      kind = .absolute
      at = date
      offsetSeconds = nil
    } else {
      kind = .relative
      at = nil
      offsetSeconds = alarm.relativeOffset
    }
  }
}
func recurrenceView(_ rules: [RecurrenceRecord]) throws -> RecurrenceView? {
  guard rules.count <= 1 else {
    throw ServerError.unsupported("multiple recurrence rules; inspect recurrenceRules")
  }
  return try rules.first.map(RecurrenceView.init)
}
