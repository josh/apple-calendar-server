import EventKit
import Foundation

// Every occurrence of a repeating event shares one eventIdentifier, and a detached
// occurrence's is "<series>/RID=<n>", which event(withIdentifier:) does not resolve. So a
// series member is addressed by its series identifier plus its current start:
// "<series>/2027-03-01T17:00:00Z", or "<series>/2027-03-01" when all-day.
enum OccurrenceKey: Equatable {
  case instant(Date)
  case day(String)
}
private let instantKeyStyle = Date.ISO8601FormatStyle()

func seriesIdentifier(_ eventIdentifier: String) -> String {
  eventIdentifier.range(of: "/RID=").map { String(eventIdentifier[..<$0.lowerBound]) }
    ?? eventIdentifier
}
func occurrenceKey(start: Date, allDay: Bool) -> String {
  allDay ? localDay(start) : start.formatted(instantKeyStyle)
}
// Splits an API event id into its series identifier and optional occurrence key.
func parseEventID(_ id: String) -> (series: String, key: OccurrenceKey?) {
  let pattern = #"/(\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}Z)?)$"#
  guard let range = id.range(of: pattern, options: .regularExpression) else { return (id, nil) }
  let series = String(id[..<range.lowerBound])
  let text = String(id[range].dropFirst())
  if text.contains("T") {
    guard let date = try? instantKeyStyle.parse(text) else { return (id, nil) }
    return (series, .instant(date))
  }
  guard (try? validateDay(text)) != nil else { return (id, nil) }
  return (series, .day(text))
}

extension EKEvent {
  // Whether the event is one occurrence of a repeating series, detached or not.
  var isSeriesMember: Bool { hasRecurrenceRules || isDetached }
}

// The event an API id names, or nil when none matches. A bare id resolves directly; for a
// repeating series that is its first occurrence. An occurrence id is re-found by its start.
@MainActor
func resolveEvent(_ store: EKEventStore, id: String) throws -> EKEvent? {
  let (series, key) = parseEventID(id)
  guard let key else { return store.event(withIdentifier: id) }
  let from: Date
  let before: Date
  switch key {
  case .instant(let date):
    from = date
    before = date.addingTimeInterval(1)
  case .day(let day):
    from = try startOfLocalDay(day)
    before = addingLocalDays(1, to: from)
  }
  let predicate = store.predicateForEvents(withStart: from, end: before, calendars: nil)
  let matches = store.events(matching: predicate).filter { event in
    guard let identifier = event.eventIdentifier,
      identifier == series || identifier.hasPrefix(series + "/"), let start = event.startDate
    else { return false }
    switch key {
    case .instant(let date): return !event.isAllDay && abs(start.timeIntervalSince(date)) < 1
    case .day(let day): return event.isAllDay && localDay(start) == day
    }
  }
  guard matches.count <= 1 else {
    throw ServerError.unsupported(
      "several occurrences of this series start at the same time; the id is ambiguous")
  }
  return matches.first
}
